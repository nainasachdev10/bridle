import { createDecipheriv, scryptSync } from "node:crypto";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { keccak256, toHex } from "viem";
import { privateKeyToAccount } from "viem/accounts";

/** Foundry keystore (Web3 Secret Storage v3, scrypt + aes-128-ctr) -> account. The key only lives in memory. */
export function decryptKeystore(json: string, password: string) {
  const c = JSON.parse(json).crypto;
  if (c.kdf !== "scrypt" || c.cipher !== "aes-128-ctr") throw new Error(`Unsupported keystore (${c.kdf}, ${c.cipher}).`);
  const { n, r, p, dklen, salt } = c.kdfparams;
  const dk = scryptSync(password, Buffer.from(salt, "hex"), dklen, { N: n, r, p, maxmem: 256 * n * r });
  const ct = Buffer.from(c.ciphertext, "hex");
  if (keccak256(Buffer.concat([dk.subarray(16, 32), ct])).slice(2) !== c.mac.toLowerCase()) throw new Error("Wrong password.");
  const d = createDecipheriv("aes-128-ctr", dk.subarray(0, 16), Buffer.from(c.cipherparams.iv, "hex"));
  return privateKeyToAccount(toHex(Buffer.concat([d.update(ct), d.final()])));
}

/** Ask without echoing what is typed. */
function askHidden(question: string): Promise<string> {
  const stdin = process.stdin;
  if (!stdin.isTTY) throw new Error("Run this in a terminal: it asks for the keystore password.");
  process.stdout.write(question);
  stdin.setRawMode(true);
  stdin.resume();
  stdin.setEncoding("utf8");
  return new Promise((resolve) => {
    let typed = "";
    const onData = (chunk: string) => {
      for (const ch of chunk) {
        if (ch === "\u0003") process.exit(130); // Ctrl-C
        if (ch === "\r" || ch === "\n") {
          stdin.setRawMode(false);
          stdin.pause();
          stdin.off("data", onData);
          process.stdout.write("\n");
          return resolve(typed);
        }
        typed = ch === "\u007f" ? typed.slice(0, -1) : typed + ch;
      }
    };
    stdin.on("data", onData);
  });
}

const unlocked = new Map<string, ReturnType<typeof decryptKeystore>>();

/** Unlock ~/.foundry/keystores/<name> once per run (same keystores `cast --account` uses). */
export async function unlock(name: string) {
  if (!unlocked.has(name)) {
    const json = readFileSync(join(homedir(), ".foundry", "keystores", name), "utf8");
    unlocked.set(name, decryptKeystore(json, await askHidden(`Password for keystore ${name}: `)));
  }
  return unlocked.get(name)!;
}
