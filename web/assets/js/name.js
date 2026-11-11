// An ENFT's optional public name. The contract takes it as a zero-padded
// bytes32 and accepts only what is checked here; see _validName in
// EndowmentNFT.sol and Annuart.Enfts.Name on the server.
import {encodeBytes32String, ZeroHash} from "ethers";

export const NAME_MAX = 31;
const ALLOWED = /^[A-Za-z0-9 \-_.']*$/;

// What is wrong with a name as typed (already trimmed), or null when it can
// be used. The empty string means "no name" and is fine.
export function nameProblem(name) {
  if (name === "") return null;
  if (!ALLOWED.test(name)) return "A name can only use letters, digits, spaces and - _ . '";
  if (name.length > NAME_MAX) return `A name can be at most ${NAME_MAX} characters.`;
  return null;
}

export function nameToBytes32(name) {
  if (name === "") return ZeroHash;
  const problem = nameProblem(name);
  if (problem || name !== name.trim()) throw new Error(problem ?? "A name cannot start or end with a space.");
  return encodeBytes32String(name);
}
