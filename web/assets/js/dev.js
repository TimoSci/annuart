// Dev-only bundle: dev wallet, dev signer, mock FHE. Referenced by the root
// layout only when :dev_wallet is on (dev and test); never part of app.js.
import {createDevSigner, accounts} from "./chain/signer/dev.js"

window.__annuartDev = {createSigner: createDevSigner, accounts}
