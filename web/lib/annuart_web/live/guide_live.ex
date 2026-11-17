defmodule AnnuartWeb.GuideLive do
  @moduledoc """
  The user guide: one page of sections with a contents list. Reading only, so
  it needs no wallet and holds no state.

  The last section is also kept, for people reading the repository, in
  `guides/keeping-the-endowment-private.md`. Change both together.
  """
  use AnnuartWeb, :live_view

  alias AnnuartWeb.Layouts

  # In reading order: {anchor, heading}.
  @sections [
    {"what-is-an-enft", "What an ENFT is"},
    {"getting-started", "Getting started"},
    {"tokens", "Getting and converting tokens"},
    {"creating", "Creating an ENFT"},
    {"owning", "Owning an ENFT"},
    {"donating", "Donating"},
    {"automatic-payouts", "Automatic payouts"},
    {"privacy", "What is private and what is public"},
    {"keeping-the-total-private", "Keeping the endowment total private"}
  ]

  def mount(_params, _session, socket),
    do: {:ok, assign(socket, page_title: "User guide", sections: @sections)}

  attr :id, :string, required: true
  slot :inner_block, required: true

  defp part(assigns) do
    assigns = assign(assigns, :title, title(assigns.id))

    ~H"""
    <section id={@id} class="area panel" data-activity-id={"panel:guide:#{@id}"}>
      <h2>{@title}</h2>
      {render_slot(@inner_block)}
    </section>
    """
  end

  defp title(id) do
    {^id, title} = List.keyfind(@sections, id, 0)
    title
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current={:guide}>
      <h1>User guide</h1>
      <p class="sub">How to use this app, and what it keeps private. No wallet needed to read it.</p>

      <div class="guide">
        <nav class="area panel" id="guide-contents" aria-label="Contents">
          <h2>Contents</h2>
          <ol>
            <li :for={{id, title} <- @sections}>
              <a href={"##{id}"} data-role="contents-link">{title}</a>
            </li>
          </ol>
        </nav>

        <.part id="what-is-an-enft">
          <p>
            An ENFT (endowment NFT) is a token that pays its owner an income over time. Its creator
            puts in a sum of money, the endowment, and sets a payout schedule. The ENFT then pays
            out according to that schedule until the endowment is used up or the schedule ends.
          </p>
          <ul>
            <li>
              <strong>The endowment is encrypted.</strong>
              Nobody can read how much is left, not even the owner.
            </li>
            <li>
              <strong>The schedule is public.</strong>
              Anyone can see how much the ENFT pays per day and for how long.
            </li>
            <li>
              <strong>The income belongs to the owner.</strong>
              Only the owner can read and claim what has been paid out so far.
            </li>
            <li>
              <strong>Everything travels with the ENFT.</strong>
              Transferring it hands over the endowment, the schedule and any unclaimed income.
            </li>
            <li>
              <strong>Nothing can be undone or changed by an administrator.</strong>
              There is no pause and no way to take an endowment back.
            </li>
          </ul>
        </.part>

        <.part id="getting-started">
          <ol>
            <li>
              <strong>Look around.</strong>
              <.link navigate={~p"/"}>Browse</.link>
              lists every ENFT on this chain and needs no wallet.
            </li>
            <li>
              <strong>Connect a wallet</strong>
              with the control at the top right. The app asks your wallet to switch network if it
              is on the wrong one.
            </li>
            <li>
              <strong>Get tokens</strong>
              on the <.link navigate={~p"/tokens"}>Tokens</.link>
              page. An endowment is paid in a
              confidential token, so you need some before you can create or donate.
            </li>
            <li>
              <strong>Create an ENFT</strong>
              on the <.link navigate={~p"/create"}>Create</.link>
              page, for yourself or for
              someone else.
            </li>
            <li>
              <strong>Find what you own</strong>
              under <.link navigate={~p"/mine"}>My ENFTs</.link>, and what you have sent under <.link navigate={
                ~p"/transactions"
              }>Transactions</.link>.
            </li>
          </ol>
        </.part>

        <.part id="tokens">
          <p>
            The <.link navigate={~p"/tokens"}>Tokens</.link> page has one card for each token this
            app works with.
          </p>
          <ul>
            <li>
              <strong>Balance.</strong>
              Your balance is encrypted on chain. Reveal decrypts it in your browser and shows it
              only to you.
            </li>
            <li>
              <strong>Authorise.</strong>
              An ENFT contract may only take tokens from you after you authorise it. Creating and
              donating do this for you when it is needed.
            </li>
            <li>
              <strong>Wrap and Unwrap.</strong>
              Wrap turns ETH into the confidential token; Unwrap turns it back. Both amounts are
              public. Unwrapping takes two steps, and an unfinished one can be finished here later.
            </li>
            <li>
              <strong>Get test tokens.</strong> On a test token, this gives you some for free.
            </li>
          </ul>
          <p class="note">Amounts below 0.000000001 ETH cannot be wrapped.</p>
        </.part>

        <.part id="creating">
          <p>
            The <.link navigate={~p"/create"}>Create</.link> page has three parts. Nothing is sent
            until you confirm the summary.
          </p>
          <ol>
            <li>
              <strong>Endowment.</strong>
              Choose the token and type the amount. The amount is encrypted in your browser before
              it is sent.
            </li>
            <li>
              <strong>Payout schedule.</strong>
              Add one or more periods, each with a length and a rate. The last period can run
              indefinitely, which means until the endowment runs out. A schedule can have at most
              256 periods. A month counts as 30 days and a year as 365.
            </li>
            <li>
              <strong>Options.</strong>
              A public name, when payouts start, whether others may donate, and who receives the
              ENFT. The name and the donation setting cannot be changed later.
            </li>
          </ol>
          <p>
            The form warns you when the amount and the schedule do not match: when the endowment
            would run out before the schedule ends, or when money would be left over at the end.
            Leftover money is paid to the owner when a schedule with an end finishes.
          </p>
          <p>
            <strong>A private-rate ENFT</strong>
            hides the payout rate as well. On the Create page its option reads
            "(SYMBOL, private payout rate)". You type one secret base payout, per day, month or
            year, and a public percentage for each period. Each period pays that share of the base
            payout. This kind has no automatic payouts.
          </p>
          <p class="note">
            An ENFT pays only what was really put in. Nobody but the creator can check that amount,
            so an ENFT can look funded and hold nothing.
          </p>
        </.part>

        <.part id="owning">
          <p>
            Open one of your ENFTs from <.link navigate={~p"/mine"}>My ENFTs</.link>. The Yours panel
            is shown only to the owner.
          </p>
          <ul>
            <li>
              <strong>Claimable.</strong>
              Reveal shows what you can claim now. It counts income up to the last accrual.
            </li>
            <li>
              <strong>Update accrual.</strong>
              Moves the income earned since the last accrual into the claimable balance. Anyone
              may do this for any ENFT.
            </li>
            <li>
              <strong>Claim.</strong>
              Pays the claimable balance to you in the confidential token. Where the token wraps
              ETH you can instead be paid in plain ETH, and that amount is public.
            </li>
            <li>
              <strong>Transfer.</strong>
              Gives the ENFT to another address. Unclaimed income goes with it, so claim first if
              you want to keep it.
            </li>
          </ul>
          <p>
            You cannot see how much endowment is left. You learn that it has run out only
            afterwards, when a claim pays less than the schedule promised.
          </p>
        </.part>

        <.part id="donating">
          <p>
            If an ENFT allows donations, anyone can add to its endowment from the Donate panel on
            its page. The amount is encrypted before it leaves your browser.
          </p>
          <ul>
            <li>A donation cannot be taken back.</li>
            <li>It makes the ENFT pay for longer; it does not change the schedule.</li>
            <li>Once the schedule has ended, the ENFT accepts no more donations.</li>
            <li>
              The amount stays hidden only while the ENFT still pays its full schedule. See <a href="#privacy">what is private and what is public</a>.
            </li>
          </ul>
        </.part>

        <.part id="automatic-payouts">
          <p>
            Some ENFT contracts can pay their owner automatically. When this is on, anyone may
            trigger a payout once the chosen interval has passed, and the owner receives it as
            plain ETH without doing anything.
          </p>
          <ul>
            <li>
              <strong>Interval.</strong>
              Payouts happen at most once per interval, from 1 hour to 365 days.
            </li>
            <li>
              <strong>Fee.</strong>
              Whoever triggers a payout is paid a fee out of it. The fee is never more than 10% of
              the payout.
            </li>
            <li>
              <strong>Settings.</strong>
              The creator chooses them when creating the ENFT, and the owner can change them or
              switch automatic payouts off on the ENFT page.
            </li>
          </ul>
          <p>
            <strong>Automatic payouts cost privacy.</strong>
            Every automatic payout amount is public. The first payout that falls short shows that
            the endowment has run out, and so shows how much the ENFT held in total. Donations made
            after that, and money left over when a schedule ends, become public too.
          </p>
        </.part>

        <.part id="privacy">
          <p>Encrypted does not always mean secret. This is what others can and cannot learn.</p>
          <ul>
            <li>
              <strong>Always public:</strong>
              the schedule, the owner and creator addresses, the name, every transaction and its
              time, and all wrapped, unwrapped and automatic payout amounts.
            </li>
            <li>
              <strong>Encrypted, but often possible to work out:</strong>
              the amount of a claim. While the ENFT pays its full schedule, a claim equals what the
              public schedule paid since the last claim.
            </li>
            <li>
              <strong>Hidden while the ENFT pays its full schedule:</strong>
              how much endowment is left, and the amounts of the endowment and of donations.
            </li>
            <li>
              <strong>Known in hindsight:</strong>
              when the endowment runs out, the owner can add up what was paid and so learns the
              total. With automatic payouts on, everyone can.
            </li>
            <li>
              <strong>Known to the creator:</strong>
              the creator knows what they put in and may tell anyone, even after giving the ENFT
              away. The owner cannot prevent it.
            </li>
            <li>
              <strong>Never sent to this app's server:</strong>
              amounts you type and amounts you reveal stay in your browser. The server can still
              work out what an ENFT may have paid from its public schedule.
            </li>
          </ul>
          <p>
            <strong>A private-rate ENFT</strong>
            hides more. The base payout rate is hidden, because it is encrypted on chain. So are
            the amount of each claim and the endowment left. These stay public: that the ENFT
            exists, the period lengths, each period's share of the base rate, the start and the
            end, and that and when an accrual, claim, donation or transfer happened.
          </p>
          <p>
            The creator and every owner so far can read the base rate. A past owner keeps that
            access, and it cannot be taken back.
          </p>
        </.part>

        <.part id="keeping-the-total-private">
          <p>
            The creator and the owner can keep the total value of an endowment from the public, but
            only on an ENFT without automatic payouts, and only if both avoid the actions below.
          </p>

          <h3>If you create the ENFT</h3>
          <ol>
            <li>
              <strong>Do not switch on automatic payouts.</strong>
              Every automatic payout amount is public, and the first short one shows everything the
              ENFT ever held.
            </li>
            <li>
              <strong>Do not wrap exactly the endowment amount.</strong>
              Wrapping shows the amount in the clear. Wrap a different, larger sum well beforehand,
              and do not unwrap the exact remainder afterwards.
            </li>
            <li>
              <strong>Do not fund the schedule exactly and then say so.</strong>
              The most a schedule with an end can pay is public, so saying it is fully funded
              publishes the total.
            </li>
            <li>
              <strong>Never disclose the amount,</strong>
              in words or on chain. You know it and can reveal it at any time.
            </li>
            <li>
              <strong>Choose the donation setting on purpose.</strong>
              With donations off, you alone know the total. With donations on, each donor knows
              their own part and may disclose it, but nobody knows the whole.
            </li>
          </ol>

          <h3>If you own the ENFT</h3>
          <ol>
            <li>
              <strong>Keep automatic payouts off</strong> for as long as you hold the ENFT.
            </li>
            <li>
              <strong>Do not unwrap claims as they arrive.</strong>
              Anyone can read an unwrapped amount. Once the ENFT has run out, an unwrap that
              matches a short claim shows the total. Keep the income in the confidential token, or
              unwrap amounts and at times that have nothing to do with your claims.
            </li>
            <li>
              <strong>Do not let your behaviour show when it ran out.</strong>
              If you visibly stop claiming from a schedule with no end, an observer can estimate
              the total from the date.
            </li>
            <li>
              <strong>Only use Reveal on a computer you trust,</strong>
              and do not share what it shows.
            </li>
            <li>
              <strong>Keep the amount private if you pass the ENFT on.</strong>
              The next owner cannot check the funding and will want to be told. Once told, the
              secret depends on them as well.
            </li>
          </ol>

          <h3>What cannot be hidden</h3>
          <ul>
            <li>
              The schedule and the time of every accrual and claim are public, so the most the ENFT
              could have paid is always known.
            </li>
            <li>
              The amount of a claim that was paid in full can usually be worked out from the
              schedule. Only the remaining endowment, and whether a claim fell short, stay hidden.
            </li>
          </ul>

          <h3>If the ENFT has a private payout rate</h3>
          <p>
            Only the base rate is hidden, not the periods. There is no automatic payout on this
            kind, because it would publish each payout and so the rate. Three things to know.
          </p>
          <ol>
            <li>
              <strong>One public amount reveals the rate.</strong>
              If an owner converts an identifiable claim to ETH, anyone can divide it by the
              elapsed weighted time and learn the base rate. That shows every payout for as long
              as the endowment lasts.
            </li>
            <li>
              <strong>A past owner keeps the rate.</strong>
              A seller still knows what the ENFT pays the buyer. Access cannot be taken back.
            </li>
            <li>
              <strong>A zero rate cannot be refused.</strong>
              The contract cannot see the rate. On a schedule with an end, a zero rate pays
              nothing until the end and then releases everything. On a schedule with no end, the
              endowment is locked for good. The owner can check by revealing the rate. A donor
              cannot.
            </li>
          </ol>
        </.part>
      </div>
    </Layouts.app>
    """
  end
end
