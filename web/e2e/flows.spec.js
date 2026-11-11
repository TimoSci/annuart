// Browser end-to-end flows against a real Hardhat node (FHEVM mock), the mock
// and wrapped deployments, and the Phoenix dev server, all started by
// playwright.config.js. The dev login (five Hardhat accounts in the #wallet
// <select>) signs, and the mock FHE client encrypts and decrypts in the page.
//
// The flows share one chain and run in order (one worker). Each creates the
// ENFTs it needs, so none depends on another's leftovers, but time only moves
// forward: a flow that moves the chain clock does so after its own ENFTs exist.
import {test, expect} from "@playwright/test";
import {execFileSync, spawn} from "node:child_process";
import {HDNodeWallet, Interface} from "ethers";
import {deploy, readDeployments, rpc, REPO_ROOT, RPC_URL} from "./global-setup.js";

const MNEMONIC = "test test test test test test test test test test test junk";
const ACCOUNTS = [0, 1, 2, 3, 4].map(i =>
  HDNodeWallet.fromPhrase(MNEMONIC, undefined, `m/44'/60'/0'/0/${i}`).address);
const DAY = 86400;
const SERVER = "localhost:4000";

// Uncaught errors and console errors in any page of a flow fail that flow.
const problems = [];
function watch(page) {
  page.on("pageerror", err => problems.push(`pageerror: ${err.message}`));
  page.on("console", msg => { if (msg.type() === "error") problems.push(`console: ${msg.text()}`); });
  return page;
}
test.beforeEach(({page}) => { problems.length = 0; watch(page); });
test.afterEach(() => { expect(problems, problems.join("\n")).toEqual([]); });

// Whether a request body or frame carries one of the privacy flow's amounts,
// 31337.42 or 271.83 MOCK (6 decimals): as typed or displayed, with any single
// separator between digit groups (comma, period, space, no-break or thin
// space, apostrophe, underscore, or such a character escaped as \uXXXX); in
// base units as decimal; or in base units as hex, which also matches inside a
// 32-byte ABI word. "31337" alone is also enough.
const SEP = "(?:[,.\\s\\u00a0\\u2009\\u202f'\\u2019_]|\\\\u[0-9a-fA-F]{4})";
const AMOUNT_PATTERNS = [
  /31337/,
  new RegExp(`31${SEP}337`),
  new RegExp(`271${SEP}83`),
  /31337420000/, /271830000/,
  new RegExp((31337420000n).toString(16), "i"), new RegExp((271830000n).toString(16), "i"),
];
const carriesAmount = text => AMOUNT_PATTERNS.some(re => re.test(text));

// Chain helpers (Node side, straight to the node).

async function advanceTime(seconds) {
  await rpc("evm_increaseTime", [seconds]);
  await rpc("evm_mine", []);
}

// Page helpers.

const wallet = page => page.locator("#wallet");

// Picks dev account `index` in the wallet control and waits until it is the
// connected one. -1 disconnects.
async function login(page, index) {
  await wallet(page).locator("select.wallet-dev").selectOption(index < 0 ? "" : String(index));
  if (index < 0) await expect(wallet(page).locator(".wallet-address")).toHaveCount(0);
  else await expect(wallet(page).locator(".wallet-address")).toHaveAttribute("title", ACCOUNTS[index]);
}

// After a full page load the wallet reconnects from the remembered choice.
async function connectedAs(page, index) {
  await expect(wallet(page).locator(".wallet-address")).toHaveAttribute("title", ACCOUNTS[index]);
}

const runButton = tx => tx.locator("button[data-role=run]");
const step = (tx, id) => tx.locator(`ol.steps li[data-step=${id}]`);

async function expectDone(tx) {
  await expect(step(tx, "mined")).toHaveAttribute("data-state", "done", {timeout: 90_000});
}

async function runTx(tx) {
  await runButton(tx).click();
  await expectDone(tx);
}

// Gives dev account `index` `whole` MOCK (6 decimals) straight from the node:
// the mock token's mint is open to anyone, and Hardhat's account 9, which no
// flow logs in as, sends it. For amounts the faucet would take many runs for.
const MINTER = HDNodeWallet.fromPhrase(MNEMONIC, undefined, "m/44'/60'/0'/0/9").address;
async function fundMock(index, whole) {
  const token = readDeployments().contracts.find(c => c.label === "mock").token;
  const data = new Interface(["function mint(address to, uint64 amount)"])
    .encodeFunctionData("mint", [ACCOUNTS[index], BigInt(whole) * 10n ** 6n]);
  const hash = await rpc("eth_sendTransaction", [{from: MINTER, to: token, data}]);
  expect((await rpc("eth_getTransactionReceipt", [hash])).status).toBe("0x1");
}

// Faucet on the Tokens page: 1000 MOCK per run.
async function getTestTokens(page, index, runs = 1) {
  await page.goto("/tokens");
  await connectedAs(page, index);
  const faucet = page.locator("#tx-faucet-mock");
  for (let i = 0; i < runs; i++) await runTx(faucet);
}

// Fills one period: `length` `unit` paying `rate` per `per`.
async function fillPeriod(form, {length = "1", unit = "days", rate = "1000", per = "day"} = {}) {
  const row = form.locator("[data-role=period]").last();
  await row.locator("[data-role=length]").fill(length);
  await row.locator("[data-role=unit]").selectOption(unit);
  await row.locator("[data-role=rate]").fill(rate);
  await row.locator("[data-role=per]").selectOption(per);
}

// Creates an ENFT through the Create page as the connected account and
// returns its token id, once the page has navigated to it.
async function createEnft(page, {label = "mock", amount = "2000", donations = true, period = {}} = {}) {
  await page.goto("/create");
  const form = page.locator("#create-form");
  await expect(form).toBeVisible();
  await form.locator("select[data-role=token]").selectOption(label);
  await form.locator("[data-role=amount]").fill(amount);
  await fillPeriod(form, period);
  await form.locator("[data-role=donations]").setChecked(donations);
  await form.locator("button[data-role=run]").click();
  const summary = form.locator("[data-role=summary]");
  await expect(summary).toBeVisible();
  await summary.locator("button[data-role=confirm]").click();
  await page.waitForURL(new RegExp(`/enft/${label}/\\d+$`), {timeout: 90_000});
  return Number(page.url().match(/\/(\d+)$/)[1]);
}

const panel = (page, name) => page.locator(`[data-activity-id="panel:enft:${name}"]`);

async function reveal(scope) {
  await scope.getByRole("button", {name: "Reveal"}).click();
  const value = scope.locator(".secret-value");
  await expect(value).not.toHaveText("•••••", {timeout: 60_000});
  return (await value.textContent()).trim();
}

const amountOf = text => Number(text.replace(/[^0-9.]/g, ""));

// A revealed amount such as "4,000.5 MOCK" in base units, exactly.
function unitsOf(text, decimals) {
  const [whole, frac = ""] = text.replace(/[^0-9.]/g, "").split(".");
  return BigInt(whole + frac.padEnd(decimals, "0"));
}

// Accepts the next confirmation dialog and resolves to its text.
function acceptDialog(page) {
  return new Promise(resolve => page.once("dialog", dialog => { resolve(dialog.message()); dialog.accept(); }));
}

// --lvl as the activity controller set it, and the computed background as
// [r, g, b] in 0..255. The computed value may be rgb(), color(srgb) or, while
// a transition runs, oklab(): painting it on a canvas gives plain sRGB.
async function brightness(locator) {
  return locator.evaluate(el => {
    const css = getComputedStyle(el).backgroundColor;
    const ctx = Object.assign(document.createElement("canvas"), {width: 1, height: 1}).getContext("2d");
    ctx.fillStyle = css;
    ctx.fillRect(0, 0, 1, 1);
    return {lvl: el.style.getPropertyValue("--lvl"), css, background: [...ctx.getImageData(0, 0, 1, 1).data.slice(0, 3)]};
  });
}

// The background color-mix(in srgb, #2b2b2e L, #141415) gives at level L.
const HOT_BG = [0x2b, 0x2b, 0x2e];
const REST_BG = [0x14, 0x14, 0x15];
const mixAt = level => HOT_BG.map((hot, i) => hot * level + REST_BG[i] * (1 - level));

// Waits for the background transition to finish at `level` (within one 8-bit step).
async function expectBackgroundAt(locator, level) {
  const want = mixAt(level);
  await expect.poll(async () => {
    const got = (await brightness(locator)).background;
    return got.every((c, i) => Math.abs(c - want[i]) <= 1) ? "at level" : `${got} (want ${want})`;
  }, {timeout: 5_000}).toBe("at level");
}

test("anonymous visitor can browse and open an ENFT but sees no owner actions", async ({browser}) => {
  // Someone else creates an ENFT first, in a context of their own.
  const creator = await browser.newContext();
  const cpage = watch(await creator.newPage());
  await cpage.goto("/");
  await login(cpage, 0);
  await getTestTokens(cpage, 0, 2);
  const id = await createEnft(cpage, {amount: "2000"});
  await creator.close();

  const context = await browser.newContext();
  const page = watch(await context.newPage());
  await page.goto("/");
  await expect(page.locator("h1")).toHaveText("Browse");
  // Not connected: the dev select offers "Not connected" and no address is shown.
  await expect(wallet(page).locator("select.wallet-dev")).toHaveValue("");
  await expect(wallet(page).locator(".wallet-address")).toHaveCount(0);

  const row = page.locator(`#enfts [data-activity-id="enft:mock:${id}"]`);
  await expect(row).toBeVisible();
  await row.click();
  await expect(page).toHaveURL(new RegExp(`/enft/mock/${id}$`));
  await expect(page.locator("h1")).toHaveText(`ENFT #${id}`);

  // The schedule is public (scheduleOf is readable): the Reader's revert
  // detection must not mistake it for a hidden one.
  await expect(panel(page, "schedule").locator("table.schedule")).toBeVisible();
  await expect(panel(page, "schedule")).not.toContainText("Private schedule");
  await expect(panel(page, "schedule").locator("table.schedule tbody tr")).toHaveCount(1);
  // 1,000 a day is stored per second, rounded down: 11,574 base units a second.
  await expect(panel(page, "schedule").locator("table.schedule tbody")).toContainText("999.9936 / day");
  await expect(panel(page, "details")).toContainText("Secret. Nobody can read this.");

  // No owner actions, no donate form: only the prompt to connect.
  await expect(page.locator("#panel-yours")).toHaveCount(0);
  await expect(page.locator("#tx-claim, #tx-transfer, #tx-donate")).toHaveCount(0);
  await expect(panel(page, "donate")).toContainText("Connect a wallet to donate.");
  await context.close();
});

test("dev login: get test tokens, create an ENFT, land on its page", async ({page}) => {
  await page.goto("/");
  await login(page, 0);

  // The wallet control survives live navigation and tells each new LiveView
  // the address again: Create (a different LiveView) renders the form, which
  // it only does once it knows the address. No full page load happens.
  await page.evaluate(() => { window.__noReload = true; });
  await page.locator('[data-activity-id="nav:create"]').click();
  await expect(page).toHaveURL(/\/create$/);
  await expect(page.locator("#create-form")).toBeVisible();
  await connectedAs(page, 0);
  await page.locator('[data-activity-id="nav:mine"]').click();
  await expect(page.locator("h1")).toHaveText("My ENFTs");
  await expect(page.locator("body")).not.toContainText("Connect a wallet to see your ENFTs.");
  await connectedAs(page, 0);
  await page.locator('[data-activity-id="nav:tokens"]').click();
  await expect(page.locator("#token-mock [data-role=authorisation]")).not.toBeEmpty();
  await connectedAs(page, 0);
  expect(await page.evaluate(() => window.__noReload)).toBe(true);

  const faucet = page.locator("#tx-faucet-mock");
  await runButton(faucet).click();
  await expect(step(faucet, "confirm")).toHaveAttribute("data-state", /active|done/);
  await expectDone(faucet);
  await runTx(faucet);

  await page.goto("/create");
  const form = page.locator("#create-form");
  await expect(form).toBeVisible();
  // The balance reveal follows the token picked in the form: it reads its
  // data attributes again, and what it showed for the other token is hidden.
  const balance = form.locator("#create-balance");
  await form.locator("select[data-role=token]").selectOption("mock");
  expect(await reveal(balance)).toMatch(/^[\d,.]+ MOCK$/);
  await form.locator("select[data-role=token]").selectOption("wrapped");
  await expect(balance.locator(".secret-value")).toHaveText("•••••");
  await expect(balance).toHaveAttribute("data-label", "wrapped");
  expect(await reveal(balance)).toMatch(/^[\d,.]+ cWETH$/);
  await form.locator("select[data-role=token]").selectOption("mock");
  await expect(balance.locator(".secret-value")).toHaveText("•••••");
  const before = await reveal(balance);
  expect(before).toMatch(/^[\d,.]+ MOCK$/);
  // The two faucet runs above pay for this create.
  expect(unitsOf(before, 6)).toBeGreaterThanOrEqual(2000n * 10n ** 6n);
  await form.locator("[data-role=amount]").fill("2000");
  await expect(form.locator(".amount-echo").first()).toHaveText("= 2000 MOCK");
  await fillPeriod(form, {length: "1", unit: "days", rate: "1000", per: "day"});
  // 1,000 a day is stored per second, rounded down, so a day pays slightly less.
  await expect(form.locator("[data-role=total]")).toHaveText("Schedule pays up to 999.9936 MOCK in total over 1 day.");
  await expect(form.locator("[data-role=donations]")).toBeChecked();

  // A summary first; nothing is sent until it is confirmed.
  await form.locator("button[data-role=run]").click();
  const summary = form.locator("[data-role=summary]");
  await expect(summary).toBeVisible();
  await expect(summary).toContainText("You are about to lock 2000 MOCK in a new ENFT.");
  await expect(form.locator("ol.steps li")).toHaveCount(0);
  // The steps can finish and the page move on between two polls, so the last
  // state each step showed is recorded in the page (live navigation keeps it).
  await form.evaluate(form => {
    window.__steps = {};
    const record = () => form.querySelectorAll("ol.steps li").forEach(li => { window.__steps[li.dataset.step] = li.dataset.state; });
    new MutationObserver(record).observe(form, {subtree: true, childList: true, attributes: true});
  });
  await summary.locator("button[data-role=confirm]").click();

  // Every step reaches its end, then the page waits for the indexer and moves on.
  await page.waitForURL(/\/enft\/mock\/\d+$/, {timeout: 90_000});
  expect(await page.evaluate(() => window.__steps)).toMatchObject({balance: "done", encrypt: "done", confirm: "done", mined: "done"});
  // Account 0 may have authorised the contract in an earlier flow.
  expect(await page.evaluate(() => window.__steps.authorise)).toMatch(/^(done|skipped)$/);
  await expect(page.locator("h1")).toHaveText(/ENFT #\d+/);
  await expect(page.locator("#panel-yours")).toBeVisible();
  await expect(panel(page, "details")).toContainText("Donations");
  await expect(panel(page, "details").locator(".kv")).toContainText("On");

  // The endowment really left the wallet: the balance fell by exactly 2000.
  await page.locator('[data-activity-id="nav:tokens"]').click();
  const after = await reveal(page.locator("#balance-mock"));
  expect(unitsOf(before, 6) - unitsOf(after, 6)).toBe(2000n * 10n ** 6n);
});

test("owner reveals, claims; a second account donates; owner transfers", async ({page}) => {
  await page.goto("/");
  await login(page, 1);
  await getTestTokens(page, 1, 2);
  const id = await createEnft(page, {amount: "2000"});
  const yours = page.locator("#panel-yours");
  await expect(yours).toBeVisible();

  await advanceTime(3600);

  // Update accrual; "Last accrued" is re-read after the confirmation.
  const lastAccrued = page.locator("[data-field=last-accrued]");
  const before = await lastAccrued.getAttribute("datetime");
  // A phx-update="ignore" region under a LiveView patch: its children (an
  // input typed into, the hook's own message line) stay as they are when the
  // confirmation below makes the server re-render the page.
  const transferBox = yours.locator("#tx-transfer");
  await transferBox.locator("input[data-arg=to]").fill(ACCOUNTS[2]);
  await expect(transferBox.locator("p.tx-message")).toHaveCount(1);
  const accrue = page.locator("#tx-accrue");
  await runTx(accrue);
  await expect(lastAccrued).not.toHaveAttribute("datetime", before ?? "");
  const after = await lastAccrued.getAttribute("datetime");
  expect(Date.parse(after)).toBeGreaterThan(Date.parse(before));
  await expect(step(accrue, "mined")).toHaveText("Done: done");
  await expect(transferBox.locator("input[data-arg=to]")).toHaveValue(ACCOUNTS[2]);
  await expect(transferBox.locator("p.tx-message")).toHaveCount(1);

  // Reveal: about an hour at 1,000 a day, so a positive amount.
  const claimable = page.locator("#secret-claimable");
  const shown = await reveal(claimable);
  expect(shown).toMatch(/ MOCK$/);
  expect(amountOf(shown)).toBeGreaterThan(0);

  await runTx(page.locator("#tx-claim"));
  // A confirmed transaction hides what was revealed; revealing again shows 0.
  await expect(claimable.locator(".secret-value")).toHaveText("•••••");
  expect(await reveal(claimable)).toBe("0 MOCK");

  // My ENFTs lists it, with the same reveal.
  await page.locator('[data-activity-id="nav:mine"]').click();
  const mine = page.locator(`#mine-mock-${id}`);
  await expect(mine).toBeVisible();
  expect(await reveal(mine.locator(`#secret-distribution-mock-${id}`))).toBe("0 MOCK");

  // A second account donates.
  await login(page, 2);
  await getTestTokens(page, 2, 1);
  await page.goto(`/enft/mock/${id}`);
  await connectedAs(page, 2);
  await expect(page.locator("#panel-yours")).toHaveCount(0);
  const donate = page.locator("#tx-donate");
  await donate.locator("input[data-arg=amount]").fill("100");
  await expect(donate.locator(".amount-echo")).toHaveText("= 100 MOCK");
  const donateQuestion = acceptDialog(page);
  await runTx(donate);
  expect(await donateQuestion).toBe(`Donate 100 MOCK to ENFT #${id}? This cannot be undone.`);

  // Back to the owner, who transfers it to account 2. The page follows the
  // indexer: once the transfer is indexed the Yours panel (and the transfer
  // control with its steps) goes, which can happen before the browser has
  // seen the receipt, so the flow waits for the owner change, not for "Done".
  await login(page, 1);
  await expect(page.locator("#panel-yours")).toBeVisible();
  const transfer = page.locator("#tx-transfer");
  await transfer.locator("input[data-arg=to]").fill(ACCOUNTS[2]);
  let confirmText = null;
  page.once("dialog", dialog => { confirmText = dialog.message(); dialog.accept(); });
  await runButton(transfer).click();
  await expect(panel(page, "details").locator(".addr").first())
    .toHaveAttribute("title", ACCOUNTS[2].toLowerCase(), {timeout: 90_000});
  expect(confirmText).toBe(`Transfer ENFT #${id} to ${ACCOUNTS[2]}? Unclaimed balance goes with the ENFT. Claim first if you want to keep it.`);
  await expect(page.locator("#panel-yours")).toHaveCount(0);
  await expect(panel(page, "history")).toContainText("Transferred to");
});

test("wrapped token: wrap 0.01 ETH, then unwrap it", async ({page}) => {
  await page.goto("/");
  await login(page, 4);
  await page.goto("/tokens");
  await connectedAs(page, 4);
  const card = page.locator("#token-wrapped");
  const eth = card.locator("[data-role=eth-balance]");
  await expect(eth).toHaveText(/ETH$/);
  const ethBefore = amountOf(await eth.textContent());

  const wrap = page.locator("#tx-wrap-wrapped");
  await wrap.locator("input[data-arg=wei]").fill("0.01");
  await expect(wrap.locator(".amount-echo")).toHaveText("= 0.01 ETH");
  await runTx(wrap);
  for (const id of ["deposit", "approve", "wrap"]) await expect(step(wrap, id)).toHaveAttribute("data-state", "done");

  const balance = page.locator("#balance-wrapped");
  const wrapped = await reveal(balance);
  expect(amountOf(wrapped)).toBe(0.01);
  await expect(eth).not.toHaveText(`${ethBefore} ETH`);

  // A revealed value does not survive a change of account, and the card
  // re-reads its chain data for the new one.
  const ethOf4 = await eth.textContent();
  await login(page, 0);
  await expect(balance.locator(".secret-value")).toHaveText("•••••");
  await expect(eth).not.toHaveText(ethOf4);
  await login(page, 4);
  await expect(eth).toHaveText(ethOf4);
  await expect(balance.locator(".secret-value")).toHaveText("•••••");

  const unwrap = page.locator("#tx-unwrap-wrapped");
  await unwrap.locator("input[data-arg=amount]").fill("0.01");
  await runTx(unwrap);
  // Exactly the whole confidential balance: the balance check lets it through.
  for (const id of ["balance", "encrypt", "request", "decrypt", "finalise", "withdraw"]) {
    await expect(step(unwrap, id)).toHaveAttribute("data-state", "done");
  }
  // Hidden by the confirmation; the confidential balance is back to zero.
  await expect(balance.locator(".secret-value")).toHaveText("•••••");
  expect(amountOf(await reveal(balance))).toBe(0);
  // Nothing left half-way: no unfinished unwraps and no stray WETH.
  await expect(card.locator("[data-role=unwraps]")).toBeHidden();
  await expect(card.locator("[data-role=weth]")).toBeHidden();
});

test("create with a later start, two periods ending indefinitely, for another address", async ({page}) => {
  await page.goto("/");
  await login(page, 0);
  await getTestTokens(page, 0, 1);
  await page.goto("/create");
  const form = page.locator("#create-form");
  await expect(form).toBeVisible();
  await form.locator("select[data-role=token]").selectOption("mock");
  await form.locator("[data-role=amount]").fill("50");

  // Rates are stored per second in base units: 8.64 a day is exactly 100 a second.
  await fillPeriod(form, {length: "2", unit: "weeks", rate: "8.64", per: "day"});
  await form.locator("button[data-role=add-period]").click();
  await expect(form.locator("[data-role=period]")).toHaveCount(2);
  // Only the last period offers "Indefinitely"; ticking it hides its length.
  await expect(form.locator("[data-role=period]").first().locator("[data-role=indefinite]")).toHaveCount(0);
  const second = form.locator("[data-role=period]").last();
  await second.locator("[data-role=indefinite]").check();
  await expect(second.locator("[data-role=length]")).toBeHidden();
  await second.locator("[data-role=rate]").fill("0.864");
  await expect(second.locator("[data-role=upto]")).toHaveText("Pays until the endowment runs out");
  await expect(form.locator("[data-role=total]")).toHaveText("Schedule pays until the endowment runs out.");
  await expect(form.locator("[data-role=chart] [data-role=bar]")).toHaveCount(2);

  // A start 30 days ahead (in the browser's local time) and another owner.
  await form.locator("[data-role=start-mode]").selectOption("at");
  const start = new Date(Date.now() + 30 * DAY * 1000);
  start.setSeconds(0, 0);
  const pad = n => String(n).padStart(2, "0");
  const local = `${start.getFullYear()}-${pad(start.getMonth() + 1)}-${pad(start.getDate())}T${pad(start.getHours())}:${pad(start.getMinutes())}`;
  await form.locator("[data-role=start-at]").fill(local);
  await form.locator("[data-role=recipient-mode]").selectOption("other");
  await form.locator("[data-role=recipient]").fill(ACCOUNTS[3]);
  await form.locator("[data-role=donations]").uncheck();

  await form.locator("button[data-role=run]").click();
  const summary = form.locator("[data-role=summary]");
  await expect(summary).toContainText(`The ENFT will belong to ${ACCOUNTS[3]}.`);
  await expect(summary).toContainText("Donations are not allowed");
  await expect(summary).toContainText("The schedule is 2 weeks at 8.64 MOCK per day, then indefinitely at 0.864 MOCK per day.");
  await summary.locator("button[data-role=confirm]").click();
  await page.waitForURL(/\/enft\/mock\/\d+$/, {timeout: 90_000});

  const details = panel(page, "details");
  await expect(details.locator(".addr").first()).toHaveAttribute("title", ACCOUNTS[3].toLowerCase());
  await expect(details).toContainText("When the endowment runs out");
  const startText = new Date(start.getTime()).toISOString().slice(0, 16).replace("T", " ") + " UTC";
  await expect(details).toContainText(startText);
  await expect(details.locator(".kv")).toContainText("Off");
  await expect(page.locator("#panel-yours")).toHaveCount(0);
  await expect(panel(page, "donate")).toHaveCount(0);
  await expect(panel(page, "schedule").locator("table.schedule tbody tr")).toHaveCount(2);
  await expect(panel(page, "schedule").locator("table.schedule tbody")).toContainText("Indefinitely");
  await expect(panel(page, "schedule").locator("[data-indefinite]")).toHaveCount(1);
});

test("a failed action shows its reason and can be retried", async ({page}) => {
  await page.goto("/");
  await login(page, 0);
  await getTestTokens(page, 0, 1);
  // The shortest schedule the form offers is one day; the chain clock is then
  // moved past its end without reloading the page, so the page still offers
  // Donate and the contract is the one to refuse.
  const id = await createEnft(page, {amount: "10", period: {length: "1", unit: "days", rate: "10", per: "day"}});
  await expect(page).toHaveURL(new RegExp(`/enft/mock/${id}$`));
  await advanceTime(2 * DAY);

  const donate = page.locator("#tx-donate");
  await donate.locator("input[data-arg=amount]").fill("5");
  const questions = [];
  page.on("dialog", dialog => { questions.push(dialog.message()); dialog.accept(); });
  await runButton(donate).click();
  const failed = donate.locator("ol.steps li[data-state=failed]");
  await expect(failed).toHaveCount(1, {timeout: 60_000});
  await expect(failed).toContainText("failed: This ENFT's schedule has ended, so it no longer accepts donations.");
  const retry = failed.getByRole("button", {name: "Try again"});
  await expect(retry).toBeVisible();

  // Trying again runs the action again, and it fails the same way. The first
  // failure is still on screen until the retry rebuilds the list, so the page
  // records whether the list ever stopped showing a failure after the click:
  // only a retry that really ran does that.
  await donate.locator("ol.steps").evaluate(list => {
    window.__retryRan = false;
    new MutationObserver(() => {
      if (list.children.length > 0 && !list.querySelector("li[data-state=failed]")) window.__retryRan = true;
    }).observe(list, {subtree: true, childList: true, attributes: true});
  });
  await retry.click();
  await expect.poll(() => page.evaluate(() => window.__retryRan), {timeout: 30_000}).toBe(true);
  await expect(donate.locator("ol.steps li[data-state=failed]"))
    .toContainText("failed: This ENFT's schedule has ended, so it no longer accepts donations.", {timeout: 60_000});
  await expect(runButton(donate)).toBeEnabled();
  // Nothing was sent (the contract refused it before), so it was "Try again"
  // both times, and each run asked the donation question again.
  await expect(donate.locator("button[data-role=start-over]")).toHaveCount(0);
  expect(questions).toEqual(Array(2).fill(`Donate 5 MOCK to ENFT #${id}? This cannot be undone.`));
});

test("activity brightness persists across reload and clears", async ({browser}) => {
  const context = await browser.newContext();
  const page = watch(await context.newPage());
  await page.goto("/");
  await login(page, 0);
  await getTestTokens(page, 0, 1);
  const id = await createEnft(page, {amount: "100", period: {length: "10", unit: "days", rate: "1", per: "day"}});

  const names = ["details", "schedule", "history"];
  for (const name of names) await panel(page, name).locator("h2").click();
  const last = panel(page, "history");
  expect((await brightness(last)).lvl).toBe("1");
  expect((await brightness(panel(page, "schedule"))).lvl).toBe("0.875");

  // The CSS cascade turns --lvl into the colour-mix background.
  await expectBackgroundAt(last, 1);
  await expectBackgroundAt(panel(page, "schedule"), 0.875);
  await expectBackgroundAt(panel(page, "sell"), 0);

  await page.reload();
  await connectedAs(page, 0);
  await expect.poll(async () => (await brightness(last)).lvl).toBe("1");
  expect((await brightness(panel(page, "details"))).lvl).toBe("0.75");
  await expectBackgroundAt(last, 1);

  // Live navigation away and back keeps it.
  await page.locator('[data-activity-id="nav:browse"]').click();
  await expect(page.locator("h1")).toHaveText("Browse");
  await page.locator(`#enfts [data-activity-id="enft:mock:${id}"]`).click();
  await expect(page.locator("h1")).toHaveText(`ENFT #${id}`);
  // nav:browse and the row were clicked since: history is three steps further down.
  await expect.poll(async () => (await brightness(last)).lvl).toBe("0.75");

  // Hovering a row that was never clicked does not brighten it.
  await page.locator('[data-activity-id="nav:browse"]').click();
  await expect(page.locator("h1")).toHaveText("Browse");
  const rows = page.locator("#enfts [data-activity-id]");
  // Newest first: the last row is the oldest ENFT, never clicked in this browser.
  const untouched = rows.last();
  const untouchedId = await untouched.getAttribute("data-activity-id");
  expect(untouchedId).not.toBe(`enft:mock:${id}`);
  await untouched.hover();
  await page.waitForTimeout(400); // longer than the .25s transition
  expect((await brightness(untouched)).lvl).toBe("0");
  await expectBackgroundAt(untouched, 0);

  // A row that arrives with a LiveView patch is painted at its level by the
  // MutationObserver. Its id is put in the history before it exists, then it
  // is created from another browser context while this page stays on Browse.
  const ids = await page.locator('#enfts [data-activity-id^="enft:mock:"]')
    .evaluateAll(els => els.map(el => Number(el.dataset.activityId.split(":")[2])));
  const nextId = Math.max(...ids) + 1;
  await page.evaluate(nextId => {
    const key = Object.keys(localStorage).find(k => k.startsWith("annuart:activity:"));
    const history = JSON.parse(localStorage.getItem(key));
    localStorage.setItem(key, JSON.stringify([`enft:mock:${nextId}`, ...history]));
  }, nextId);
  await page.reload();
  await connectedAs(page, 0);
  // Count style writes on activity elements, to show the observer settles.
  await page.evaluate(() => {
    window.__styleWrites = 0;
    new MutationObserver(records => {
      window.__styleWrites += records.filter(r => r.attributeName === "style").length;
    }).observe(document.documentElement, {subtree: true, attributes: true, attributeFilter: ["style"]});
  });
  const other = await browser.newContext();
  const opage = watch(await other.newPage());
  await opage.goto("/");
  await login(opage, 3);
  await getTestTokens(opage, 3, 1);
  expect(await createEnft(opage, {amount: "100", period: {length: "10", unit: "days", rate: "1", per: "day"}})).toBe(nextId);
  await other.close();
  const arrived = page.locator(`#enfts [data-activity-id="enft:mock:${nextId}"]`);
  await expect(arrived).toBeVisible({timeout: 30_000});
  await expect.poll(async () => (await brightness(arrived)).lvl).toBe("1");
  await expectBackgroundAt(arrived, 1);
  const writes = await page.evaluate(() => window.__styleWrites);
  await page.waitForTimeout(1000);
  expect(await page.evaluate(() => window.__styleWrites)).toBe(writes);

  // Another dev account has its own history; switching back restores this one.
  await login(page, 1);
  await expect.poll(async () => (await brightness(arrived)).lvl).toBe("0");
  await login(page, 0);
  await expect.poll(async () => (await brightness(arrived)).lvl).toBe("1");

  // Clear: everything back to resting, and it stays so after a reload.
  await page.locator("#clear-activity").click();
  const levels = () => page.locator("[data-activity-id]").evaluateAll(els => [...new Set(els.map(el => el.style.getPropertyValue("--lvl")))]);
  expect(await levels()).toEqual(["0"]);
  await page.reload();
  await connectedAs(page, 0);
  await expect.poll(levels).toEqual(["0"]);
  await context.close();
});

test("no request body or websocket frame contains the entered amount", async ({page}) => {
  // Everything the browser sends to the Phoenix server (localhost:4000):
  // every HTTP request body and every websocket frame (LiveView and live
  // reload). Requests to the Hardhat node at 8545 are not the server and are
  // left out: the mock FHE client sends the cleartext there by design (the
  // mock "encrypts" by handing the value to the node). With the real relayer
  // that traffic goes to the relayer instead, never to this server.
  const sent = [];
  const toNode = [];
  const toServer = url => new URL(url).host === SERVER;
  page.on("request", request => {
    const data = `${request.url()}\n${request.postData() ?? ""}`;
    if (toServer(request.url())) sent.push({kind: "http", url: request.url(), data});
    else if (request.url().startsWith(RPC_URL)) toNode.push(data);
  });
  page.on("websocket", ws => {
    if (!toServer(ws.url())) return;
    sent.push({kind: "ws-open", data: ws.url()});
    ws.on("framesent", frame => sent.push({kind: "ws", data: String(frame.payload)}));
  });

  await page.goto("/");
  await login(page, 0);
  // Enough for the endowment and the donation below.
  await fundMock(0, 32_000);
  const id = await createEnft(page, {amount: "31337.42", period: {length: "1", unit: "years", rate: "10", per: "day"}});
  await expect(page.locator("#panel-yours")).toBeVisible();

  const donate = page.locator("#tx-donate");
  await donate.locator("input[data-arg=amount]").fill("271.83");
  await expect(donate.locator(".amount-echo")).toHaveText("= 271.83 MOCK");
  const question = acceptDialog(page);
  await runTx(donate);
  // Asked in the page; a dialog is not sent anywhere.
  expect(await question).toBe(`Donate 271.83 MOCK to ENFT #${id}? This cannot be undone.`);
  await expect(page).toHaveURL(new RegExp(`/enft/mock/${id}$`));

  // The matcher is checked before it is trusted: it must flag every form an
  // amount could leak in, and must not flag an ordinary frame.
  const baseUnits = [31337420000n, 271830000n];
  for (const leak of [
    "31337.42", "31,337.42", "31 337,42", "31\u00a0337.42", "31\u2009337.42", "31'337.42", "31_337.42",
    "271.83", "271,83", "271 83", '{"amount":31337.42}', '{"amount":271.83}',
    "31337420000", "271830000",
    "0x" + 31337420000n.toString(16).padStart(64, "0"), (271830000n).toString(16).padStart(64, "0"),
    '["4","7","lv:phx-F1","event",{"type":"hook","event":"tx:confirmed","value":{"note":"= 31,337.42 MOCK"}}]',
    '["4","8","lv:phx-F1","event",{"type":"click","event":"x","value":{"value":"271\\u00a083"}}]',
  ]) expect(carriesAmount(leak), `matcher misses ${leak}`).toBe(true);
  for (const clean of [
    '["4","7","lv:phx-F1","event",{"type":"hook","event":"tx:confirmed","value":{"action":"donate","label":"mock","tokenId":"3","hash":"0x5e0c7a9d4b2f81c6aa03e4d7f9b1c2a8e6d5f40b3c2a1908f7e6d5c4b3a29180"}}]',
    '["4","9","lv:phx-F1","event",{"type":"hook","event":"wallet:changed","value":{"address":"0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"}}]',
  ]) expect(carriesAmount(clean), `matcher flags a clean frame: ${clean}`).toBe(false);
  // The recording works: the server did get traffic of both kinds.
  expect(sent.filter(s => s.kind === "ws").length).toBeGreaterThan(0);
  expect(sent.filter(s => s.kind === "http").length).toBeGreaterThan(0);
  // And the amounts really were entered and sent: the mock hands each one, in
  // hex, to the node (excluded above, as it is not the server).
  for (const n of baseUnits) expect(toNode.some(d => d.toLowerCase().includes(n.toString(16)))).toBe(true);

  const leaks = sent.filter(s => carriesAmount(s.data));
  expect(leaks, JSON.stringify(leaks.slice(0, 3))).toEqual([]);
});

test("after the node is restarted and redeployed, Browse shows only the new chain's ENFTs", async ({browser}) => {
  const context = await browser.newContext();
  const page = watch(await context.newPage());
  await page.goto("/");
  await expect(page.locator("#enfts [data-activity-id]").first()).toBeVisible();
  expect(await page.locator("#enfts [data-activity-id]").count()).toBeGreaterThan(1);

  // Stop the node Playwright started and start a fresh one on the same port,
  // while Phoenix keeps running. The new node is this test's to stop.
  const pid = nodePid();
  process.kill(pid, "SIGTERM");
  await waitFor(async () => !(await reachable()), "the old node to stop");
  const node = spawn("npx", ["hardhat", "node"], {cwd: REPO_ROOT, stdio: "ignore", detached: true});
  try {
    await waitFor(reachable, "the new node to answer", 120_000);
    deploy();
    // A fresh node with the same deploy order reuses the same addresses.
    expect(readDeployments().contracts.map(c => c.label).sort()).toEqual(["mock", "wrapped"]);

    // The indexer notices the chain changed and rebuilds: no ENFTs at all.
    await expect(page.locator("#enfts [data-activity-id]")).toHaveCount(0, {timeout: 30_000});
    await expect(page.locator("main")).toContainText("No ENFTs yet.");

    // One ENFT on the new chain, and only that one is listed.
    await login(page, 0);
    await getTestTokens(page, 0, 1);
    const id = await createEnft(page, {amount: "10", period: {length: "1", unit: "days", rate: "1", per: "day"}});
    expect(id).toBe(1);
    await page.goto("/");
    await expect(page.locator("#enfts [data-activity-id]")).toHaveCount(1);
    await expect(page.locator('#enfts [data-activity-id="enft:mock:1"]')).toBeVisible();
  } finally {
    await context.close();
    try { process.kill(-node.pid, "SIGTERM"); } catch { /* already gone */ }
  }
});

async function reachable() {
  try {
    await rpc("eth_chainId");
    return true;
  } catch {
    return false;
  }
}

async function waitFor(check, what, timeout = 30_000) {
  const until = Date.now() + timeout;
  while (Date.now() < until) {
    if (await check()) return;
    await new Promise(r => setTimeout(r, 250));
  }
  throw new Error(`timed out waiting for ${what}`);
}

// The process listening on the node's port.
function nodePid() {
  const port = new URL(RPC_URL).port;
  const out = execFileSync("lsof", ["-t", `-iTCP:${port}`, "-sTCP:LISTEN"], {encoding: "utf8"}).trim();
  return Number(out.split("\n")[0]);
}
