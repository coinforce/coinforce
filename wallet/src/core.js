/*! COINFORCE Web3 cüzdan çekirdeği (saklamasız / non-custodial)
 * Kurtarma ifadesi ve özel anahtarlar yalnızca kullanıcının cihazında üretilir ve şifreli saklanır;
 * bu dosya hiçbir anahtarı, ifadeyi ya da şifreyi ağ üzerinden göndermez. Ağ istekleri yalnızca
 * herkese açık blokzincir RPC uçlarına (bakiye okuma, işlem yayınlama) yapılır.
 * Paketlenen kütüphaneler (hepsi MIT lisanslı): ethers 6.17.0, @solana/web3.js 1.98.4,
 * @scure/bip39 2.4.0, @noble/hashes 2.4.0 (ve bağımlılıkları). Lisans metinleri: wallet/LICENSES.txt
 */
import { generateMnemonic, mnemonicToSeedSync, validateMnemonic } from "@scure/bip39";
import { wordlist } from "@scure/bip39/wordlists/english.js";
import { hmac } from "@noble/hashes/hmac.js";
import { sha512 } from "@noble/hashes/sha2.js";
import { HDNodeWallet, JsonRpcProvider, Contract, Interface, Network, isAddress, getAddress, parseUnits, formatUnits } from "ethers";
import { Connection, PublicKey, Keypair, SystemProgram, TransactionInstruction, TransactionMessage, VersionedTransaction, ComputeBudgetProgram } from "@solana/web3.js";

export const VERSION = "1.0.0";
export const SOL_PATH = "m/44'/501'/0'/0'";   // Phantom / Solflare varsayılanı
export const EVM_PATH = "m/44'/60'/0'/0/0";    // MetaMask varsayılanı
export const KDF_IT = 600000;                  // PBKDF2-SHA256 (OWASP 2023 önerisi)
export { wordlist };

const TOKEN = "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA";
const TOKEN22 = "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb";
const ATA = "ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL";
const enc = new TextEncoder(), dec = new TextDecoder();
const sleep = ms => new Promise(r => setTimeout(r, ms));

// ---------- Ağlar (adresler bağımsız listelerle doğrulandı: Jupiter doğrulanmış token listesi, Uniswap varsayılan listesi)
export const NETS = {
  main: {
    sol: { id: "sol", name: "Solana", sym: "SOL", dec: 9, rpc: ["https://api.mainnet-beta.solana.com", "https://solana-rpc.publicnode.com"], tx: "solscan.io/tx/", acct: "solscan.io/account/", q: "",
      mints: { EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v: "USDC", Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB: "USDT", DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263: "BONK",
        EKpQGSJtjMFqKZ9KQanSqYXRcF8fBopzLHYxdM65zcjm: "WIF", JUPyiwrYJFskUPiHa7hkeR8VUtAeFoSYbKedZNsDvCN: "JUP", "7GCihgDB8fe6KNjn2MYtkzZcRjQy3t9GHdC8uHYmW2hr": "POPCAT",
        ukHH6c7mMyiWCf1b9pnWe25TSpkDDt3H5pQZgZ74J82: "BOME", MEW1gQWJ3nEXg2qgERiKu7FAFj79PHvQVREQUzScPP5: "MEW" } },
    evm: [
      { id: "eth", name: "Ethereum", chainId: 1, sym: "ETH", dec: 18, rpc: ["https://ethereum-rpc.publicnode.com"], tx: "etherscan.io/tx/", acct: "etherscan.io/address/",
        tokens: [["USDT", "0xdAC17F958D2ee523a2206206994597C13D831ec7", 6], ["USDC", "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48", 6]] },
      { id: "bsc", name: "BNB Chain", chainId: 56, sym: "BNB", dec: 18, rpc: ["https://bsc-rpc.publicnode.com"], tx: "bscscan.com/tx/", acct: "bscscan.com/address/",
        tokens: [["USDT", "0x55d398326f99059fF775485246999027B3197955", 18], ["USDC", "0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d", 18]] },
      { id: "base", name: "Base", chainId: 8453, sym: "ETH", dec: 18, rpc: ["https://base-rpc.publicnode.com"], tx: "basescan.org/tx/", acct: "basescan.org/address/",
        tokens: [["USDC", "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913", 6], ["USDT", "0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2", 6]] }
    ]
  },
  test: {
    sol: { id: "sol", name: "Solana Devnet", sym: "SOL", dec: 9, rpc: ["https://api.devnet.solana.com"], tx: "solscan.io/tx/", acct: "solscan.io/account/", q: "?cluster=devnet", mints: {} },
    evm: [{ id: "sep", name: "Sepolia", chainId: 11155111, sym: "ETH", dec: 18, rpc: ["https://ethereum-sepolia-rpc.publicnode.com"], tx: "sepolia.etherscan.io/tx/", acct: "sepolia.etherscan.io/address/", tokens: [] }]
  }
};
export function chainOf(net, id) { const N = NETS[net]; if (!N) throw new Error("bad-net"); return id === "sol" ? N.sol : N.evm.find(c => c.id === id) }

// ---------- Kurtarma ifadesi ve hesaplar
export const normPhrase = s => String(s || "").normalize("NFKD").toLowerCase().trim().split(/\s+/).filter(Boolean).join(" ");
export const newPhrase = () => generateMnemonic(wordlist, 128);            // 12 kelime, crypto.getRandomValues
export const phraseOk = s => { const p = normPhrase(s), n = p.split(" ").length; return (n === 12 || n === 24) && validateMnemonic(p, wordlist) };
export function phraseCheck(s) {          // içe aktarma sırasında anlık geri bildirim
  const w = normPhrase(s).split(" ").filter(Boolean), set = new Set(wordlist);
  return { n: w.length, bad: w.map((x, i) => set.has(x) ? -1 : i).filter(i => i >= 0), ok: (w.length === 12 || w.length === 24) && validateMnemonic(w.join(" "), wordlist) };
}
// SLIP-0010 ed25519 (yalnızca sertleştirilmiş adımlar)
export function slip10(seed, path) {
  let I = hmac(sha512, enc.encode("ed25519 seed"), seed), k = I.slice(0, 32), c = I.slice(32);
  for (const seg of path.split("/").slice(1)) {
    if (!/^\d+'$/.test(seg)) throw new Error("ed25519: yalnızca sertleştirilmiş yol");
    const d = new Uint8Array(37); d.set(k, 1); new DataView(d.buffer).setUint32(33, (parseInt(seg, 10) + 0x80000000) >>> 0, false);
    I = hmac(sha512, c, d); k = I.slice(0, 32); c = I.slice(32);
  }
  return k;
}
function solKeypair(phrase) {
  const seed = mnemonicToSeedSync(normPhrase(phrase), ""), k = slip10(seed, SOL_PATH), kp = Keypair.fromSeed(k);
  seed.fill(0); k.fill(0); return kp;
}
const evmWallet = phrase => HDNodeWallet.fromPhrase(normPhrase(phrase), "", EVM_PATH);
export function accounts(phrase) { return { sol: solKeypair(phrase).publicKey.toBase58(), evm: evmWallet(phrase).address } }

// ---------- Cihazda şifreli saklama: PBKDF2-SHA256 → AES-256-GCM
const b64 = u => { let s = ""; for (const x of u) s += String.fromCharCode(x); return btoa(s) };
const unb64 = s => Uint8Array.from(atob(s), c => c.charCodeAt(0));
async function aesKey(pw, salt, it) {
  if (!globalThis.crypto || !crypto.subtle) throw fail("insecure");   // WebCrypto yalnızca HTTPS sayfalarda vardır
  const base = await crypto.subtle.importKey("raw", enc.encode(String(pw).normalize("NFKC")), "PBKDF2", false, ["deriveKey"]);
  return crypto.subtle.deriveKey({ name: "PBKDF2", hash: "SHA-256", salt, iterations: it }, base, { name: "AES-GCM", length: 256 }, false, ["encrypt", "decrypt"]);
}
export async function seal(phrase, pw, aad) {
  const salt = crypto.getRandomValues(new Uint8Array(16)), iv = crypto.getRandomValues(new Uint8Array(12)), key = await aesKey(pw, salt, KDF_IT);
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv, additionalData: enc.encode(aad || "") }, key, enc.encode(normPhrase(phrase))));
  return { v: 1, kdf: "pbkdf2-sha256", it: KDF_IT, salt: b64(salt), iv: b64(iv), ct: b64(ct) };
}
export async function unseal(blob, pw, aad) {
  if (!blob || blob.v !== 1 || blob.kdf !== "pbkdf2-sha256") throw fail("bad-blob");
  let pt;
  try {
    const key = await aesKey(pw, unb64(blob.salt), +blob.it || KDF_IT);
    pt = await crypto.subtle.decrypt({ name: "AES-GCM", iv: unb64(blob.iv), additionalData: enc.encode(aad || "") }, key, unb64(blob.ct));
  } catch (e) { if (e && e.code === "insecure") throw e; throw fail("bad-password") }
  const p = dec.decode(pt); if (!phraseOk(p)) throw fail("bad-blob"); return p;
}

// ---------- Tutarlar (tam sayı birimleriyle, ondalık hatası yok)
export function toRaw(str, decimals) {
  let s = String(str || "").trim().replace(/\s/g, "").replace(",", ".");
  if (!/^\d*\.?\d*$/.test(s) || s === "" || s === ".") return null;
  const [a, b = ""] = s.split("."); s = (a || "0") + (b ? "." + b.slice(0, decimals) : "");
  try { const r = parseUnits(s, decimals); return r > 0n ? r : null } catch (e) { return null }
}
export const fromRaw = (raw, decimals) => formatUnits(BigInt(raw || 0), decimals);

// ---------- Adres doğrulama
export function solAddr(s) {
  s = String(s || "").trim();
  try { const pk = new PublicKey(s); if (pk.toBase58() !== s) return { ok: false }; return { ok: true, addr: s, onCurve: PublicKey.isOnCurve(pk.toBytes()) } } catch (e) { return { ok: false } }
}
export function evmAddr(s) {
  s = String(s || "").trim(); if (!/^0x[0-9a-fA-F]{40}$/.test(s) || !isAddress(s)) return { ok: false };
  return { ok: true, addr: getAddress(s), zero: /^0x0{40}$/i.test(s) };
}

// ---------- RPC yardımcıları
const CONN = {}, PROV = {};
const solConn = u => CONN[u] || (CONN[u] = new Connection(u, { commitment: "confirmed" }));
const evmProv = (C, u) => PROV[C.chainId + "|" + u] || (PROV[C.chainId + "|" + u] = new JsonRpcProvider(u, Network.from(C.chainId), { staticNetwork: true, batchMaxCount: 10, cacheTimeout: -1 }));
async function withRpc(urls, fn) { let last; for (const u of urls) { try { return await fn(u) } catch (e) { last = e; if (e && e.userFacing) throw e } } throw last }
const fail = (code, extra) => Object.assign(new Error(code), { code, userFacing: true }, extra || {});
const ERC20 = new Interface(["function balanceOf(address) view returns (uint256)", "function transfer(address,uint256) returns (bool)"]);

// ---------- Bakiyeler
async function solBalances(C, owner) {
  return withRpc(C.rpc, async u => {
    const cn = solConn(u), pk = new PublicKey(owner);
    const [lam, t1, t2] = await Promise.all([cn.getBalance(pk), cn.getParsedTokenAccountsByOwner(pk, { programId: new PublicKey(TOKEN) }), cn.getParsedTokenAccountsByOwner(pk, { programId: new PublicKey(TOKEN22) })]);
    const rows = [{ net: "sol", netName: C.name, sym: "SOL", name: "Solana", dec: 9, raw: String(lam), native: true }], by = {};
    for (const [arr, prog] of [[t1.value, TOKEN], [t2.value, TOKEN22]]) for (const a of arr) {
      const info = a.account.data && a.account.data.parsed && a.account.data.parsed.info, amt = info && info.tokenAmount;
      if (!amt || amt.amount === "0" || info.state === "frozen") continue;
      const raw = BigInt(amt.amount), m = info.mint, cur = by[m];
      if (!cur) by[m] = { net: "sol", netName: C.name, mint: m, prog, dec: amt.decimals, raw, acct: a.pubkey.toBase58(), acctRaw: raw };
      else { cur.raw += raw; if (raw > cur.acctRaw) { cur.acct = a.pubkey.toBase58(); cur.acctRaw = raw } }
    }
    for (const r of Object.values(by)) { const sym = C.mints[r.mint] || null; rows.push(Object.assign(r, { sym, name: sym, raw: String(r.raw), acctRaw: String(r.acctRaw) })) }
    return rows;
  });
}
async function evmBalances(C, owner) {
  return withRpc(C.rpc, async u => {
    const p = evmProv(C, u), nat = await p.getBalance(owner);
    const toks = await Promise.all(C.tokens.map(([sym, addr, d]) => new Contract(addr, ERC20, p).balanceOf(owner).then(b => ({ net: C.id, netName: C.name, sym, name: sym, dec: d, raw: b.toString(), token: addr }))));
    return [{ net: C.id, netName: C.name, sym: C.sym, name: C.sym === "ETH" ? "Ether" : C.sym, dec: 18, raw: nat.toString(), native: true }].concat(toks.filter(t => t.raw !== "0"));
  });
}
export async function balances(net, addrs) {
  const N = NETS[net], list = [], errs = [], jobs = [];
  if (addrs && addrs.sol) jobs.push(solBalances(N.sol, addrs.sol).then(r => list.push(...r), e => errs.push({ net: "sol", msg: String(e && e.message || e) })));
  if (addrs && addrs.evm) for (const C of N.evm) jobs.push(evmBalances(C, addrs.evm).then(r => list.push(...r), e => errs.push({ net: C.id, msg: String(e && e.message || e) })));
  await Promise.all(jobs); return { list, errs, at: Date.now() };
}

// ---------- Solana gönderimi
function ataOf(owner, mint, prog) { return PublicKey.findProgramAddressSync([owner.toBuffer(), new PublicKey(prog).toBuffer(), mint.toBuffer()], new PublicKey(ATA))[0] }
function solIxs(from, to, a, raw, needAta) {
  if (a.native) return [SystemProgram.transfer({ fromPubkey: from, toPubkey: to, lamports: raw })];
  const mint = new PublicKey(a.mint), prog = new PublicKey(a.prog), dst = ataOf(to, mint, a.prog), ixs = [];
  if (needAta) ixs.push(new TransactionInstruction({ programId: new PublicKey(ATA), data: Uint8Array.of(1), keys: [   // CreateIdempotent
    { pubkey: from, isSigner: true, isWritable: true }, { pubkey: dst, isSigner: false, isWritable: true }, { pubkey: to, isSigner: false, isWritable: false },
    { pubkey: mint, isSigner: false, isWritable: false }, { pubkey: SystemProgram.programId, isSigner: false, isWritable: false }, { pubkey: prog, isSigner: false, isWritable: false }] }));
  const data = new Uint8Array(10); data[0] = 12; new DataView(data.buffer).setBigUint64(1, BigInt(raw), true); data[9] = a.dec;   // TransferChecked
  ixs.push(new TransactionInstruction({ programId: prog, data, keys: [{ pubkey: new PublicKey(a.acct), isSigner: false, isWritable: true }, { pubkey: mint, isSigner: false, isWritable: false },
    { pubkey: dst, isSigner: false, isWritable: true }, { pubkey: from, isSigner: true, isWritable: false }] }));
  return ixs;
}
const solMsg = (from, bh, ixs) => new TransactionMessage({ payerKey: from, recentBlockhash: bh, instructions: ixs }).compileToLegacyMessage();
// Gönderim planı: doğrulama + simülasyon + ücret. İmza YOK.
export async function solPlan({ net, from, to, asset, raw, max }) {
  const C = NETS[net].sol, A = solAddr(to); raw = BigInt(raw || 0);
  if (!A.ok) throw fail("bad-address");
  if (!A.onCurve) throw fail("off-curve");
  if (A.addr === from) throw fail("self");
  if (max && !asset.native) raw = BigInt(asset.acctRaw);
  if (!max && raw <= 0n) throw fail("bad-amount");
  if (!asset.native && raw > BigInt(asset.acctRaw)) throw fail("insufficient");
  return withRpc(C.rpc, async u => {
    const cn = solConn(u), fromPk = new PublicKey(from), toPk = new PublicKey(A.addr);
    let needAta = false, ataRent = 0n;
    const [balN, rent0, toInfo] = await Promise.all([cn.getBalance(fromPk), cn.getMinimumBalanceForRentExemption(0), cn.getAccountInfo(toPk)]);
    const bal = BigInt(balN);
    if (toInfo && (toInfo.owner.toBase58() === TOKEN || toInfo.owner.toBase58() === TOKEN22)) throw fail("token-account");
    if (asset.native && !max && raw > bal) throw fail("insufficient");
    if (asset.native && !max && !toInfo && raw < BigInt(rent0)) throw fail("min-new", { min: String(rent0) });
    if (asset.native && !max) { const l = bal - raw - 5000n; if (l > 0n && l < BigInt(rent0)) throw fail("dust-left", { min: String(rent0), max: String(bal - 5000n) }) }
    if (!asset.native) {
      const dst = ataOf(toPk, new PublicKey(asset.mint), asset.prog);
      if (!(await cn.getAccountInfo(dst))) { needAta = true; ataRent = BigInt(await cn.getMinimumBalanceForRentExemption(165)) }
    }
    // Öncelik ücreti: son bloklardaki ücretlerin 75. yüzdeliği (sınırlı)
    let price = 0;
    try { const f = (await cn.getRecentPrioritizationFees({ lockedWritableAccounts: [fromPk] })).map(x => x.prioritizationFee).filter(x => x > 0).sort((a, b) => a - b); if (f.length) price = f[Math.floor(f.length * .75)] } catch (e) {}
    price = Math.min(Math.max(price, net === "main" ? 1000 : 0), 200000);
    const simRaw = asset.native && max ? (bal > 400000n ? bal - 400000n : 1n) : raw;   // tüm bakiye: ücreti ölçmek için yaklaşık tutarla simüle et
    const { blockhash } = await cn.getLatestBlockhash("confirmed");
    const sim = await cn.simulateTransaction(new VersionedTransaction(solMsg(fromPk, blockhash, [ComputeBudgetProgram.setComputeUnitLimit({ units: 200000 }), ComputeBudgetProgram.setComputeUnitPrice({ microLamports: price }), ...solIxs(fromPk, toPk, asset, simRaw, needAta)])), { sigVerify: false, replaceRecentBlockhash: true });
    if (sim.value.err && !(asset.native && max)) {
      const d = JSON.stringify(sim.value.err);
      if (asset.native && /InsufficientFundsForRent/.test(d)) throw fail(toInfo ? "dust-left" : "min-new", { min: String(rent0) });
      throw fail("sim-failed", { detail: d, logs: (sim.value.logs || []).slice(-6) });
    }
    const units = Math.min(1400000, Math.max(1000, Math.ceil((sim.value.unitsConsumed || 1000) * 1.3) + 300));
    const fee = 5000n + BigInt(Math.ceil(units * price / 1e6));
    if (asset.native && max) { raw = bal - fee; if (raw <= 0n) throw fail("insufficient-fee", { need: String(fee), have: String(bal) }) }
    if (asset.native && !toInfo && raw < BigInt(rent0)) throw fail("min-new", { min: String(rent0) });
    const need = fee + ataRent + (asset.native ? raw : 0n);
    if (bal < need) throw fail("insufficient-fee", { need: String(need), have: String(bal) });
    if (asset.native) { const left = bal - need; if (left > 0n && left < BigInt(rent0)) throw fail("dust-left", { min: String(rent0), max: String(bal - fee) }) }
    return { chain: "sol", net, from, to: A.addr, asset, raw: String(raw), units, price, fee: String(fee), ataRent: String(ataRent), needAta, newAcct: !toInfo, total: String(need) };
  });
}
// İmzala, yayınla, onayı bekle. Kurtarma ifadesi yalnızca bu fonksiyonun içinde kullanılır.
export async function solSend(plan, phrase, onStatus) {
  const C = NETS[plan.net].sol, kp = solKeypair(phrase);
  if (kp.publicKey.toBase58() !== plan.from) throw fail("wallet-mismatch");
  const cn = solConn(C.rpc[0]), ixs = [ComputeBudgetProgram.setComputeUnitLimit({ units: plan.units }), ComputeBudgetProgram.setComputeUnitPrice({ microLamports: plan.price }),
    ...solIxs(kp.publicKey, new PublicKey(plan.to), plan.asset, BigInt(plan.raw), plan.needAta)];
  const { blockhash, lastValidBlockHeight } = await cn.getLatestBlockhash("confirmed");
  const tx = new VersionedTransaction(solMsg(kp.publicKey, blockhash, ixs)); tx.sign([kp]);
  const wire = tx.serialize(), sig = await cn.sendRawTransaction(wire, { skipPreflight: false, preflightCommitment: "confirmed", maxRetries: 5 });
  onStatus && onStatus({ stage: "sent", sig });
  for (let i = 0; i < 120; i++) {
    await sleep(1500);
    const s = (await cn.getSignatureStatuses([sig])).value[0];
    if (s && s.err) throw fail("tx-failed", { sig, detail: JSON.stringify(s.err) });
    if (s && (s.confirmationStatus === "confirmed" || s.confirmationStatus === "finalized")) return { sig, slot: s.slot };
    if (i % 3 === 2) { if ((await cn.getBlockHeight("confirmed")) > lastValidBlockHeight) throw fail("expired", { sig }); cn.sendRawTransaction(wire, { skipPreflight: true, maxRetries: 0 }).catch(() => {}) }
  }
  throw fail("timeout", { sig });
}

// ---------- EVM gönderimi
export async function evmPlan({ net, chain, from, to, asset, raw, max }) {
  const C = chainOf(net, chain), A = evmAddr(to); raw = BigInt(raw || 0);
  if (!C) throw fail("bad-net");
  if (!A.ok) throw fail("bad-address");
  if (A.zero) throw fail("zero-address");
  if (A.addr.toLowerCase() === from.toLowerCase()) throw fail("self");
  if (!max && raw <= 0n) throw fail("bad-amount");
  return withRpc(C.rpc, async u => {
    const p = evmProv(C, u);
    const [bal, fd, code] = await Promise.all([p.getBalance(from), p.getFeeData(), p.getCode(A.addr)]);
    if (!asset.native) { const tb = await new Contract(asset.token, ERC20, p).balanceOf(from); if (max) raw = tb; if (raw <= 0n || raw > tb) throw fail("insufficient") }
    else if (!max && raw > bal) throw fail("insufficient");
    const mk = v => asset.native ? { from, to: A.addr, value: v } : { from, to: asset.token, value: 0n, data: ERC20.encodeFunctionData("transfer", [A.addr, v]) };
    let gas; try { gas = await p.estimateGas(mk(asset.native && max ? 1n : raw)) } catch (e) { throw fail("estimate-failed", { detail: String(e && (e.shortMessage || e.message) || e) }) }
    const gasLimit = asset.native && code === "0x" ? gas : gas * 12n / 10n;
    const eip1559 = fd.maxFeePerGas != null, maxFee = eip1559 ? fd.maxFeePerGas : fd.gasPrice;
    const fee = gasLimit * maxFee;
    if (asset.native && max) { raw = bal - fee; if (raw <= 0n) throw fail("insufficient-fee", { need: String(fee), have: String(bal) }) }
    const tx = mk(raw), need = fee + (asset.native ? raw : 0n);
    if (bal < need) throw fail("insufficient-fee", { need: String(need), have: String(bal) });
    return { chain: C.id, net, chainId: C.chainId, from, to: A.addr, asset, raw: String(raw), txTo: tx.to, data: tx.data || "0x", value: String(tx.value), gasLimit: String(gasLimit),
      eip1559, maxFeePerGas: String(maxFee), maxPriorityFeePerGas: eip1559 ? String(fd.maxPriorityFeePerGas) : null, fee: String(fee), total: String(need), toIsContract: code !== "0x" };
  });
}
export async function evmSend(plan, phrase, onStatus) {
  const C = chainOf(plan.net, plan.chain), p = evmProv(C, C.rpc[0]), w = evmWallet(phrase).connect(p);
  if (w.address !== plan.from) throw fail("wallet-mismatch");
  const nonce = await p.getTransactionCount(w.address, "pending");
  const req = { chainId: plan.chainId, to: plan.txTo, value: BigInt(plan.value), data: plan.data, gasLimit: BigInt(plan.gasLimit), nonce };
  if (plan.eip1559) Object.assign(req, { type: 2, maxFeePerGas: BigInt(plan.maxFeePerGas), maxPriorityFeePerGas: BigInt(plan.maxPriorityFeePerGas) }); else Object.assign(req, { type: 0, gasPrice: BigInt(plan.maxFeePerGas) });
  let r; try { r = await w.sendTransaction(req) } catch (e) { throw fail("send-failed", { detail: String(e && (e.shortMessage || e.message) || e) }) }
  onStatus && onStatus({ stage: "sent", hash: r.hash });
  const rc = await r.wait(1, 180000);
  if (!rc || rc.status !== 1) throw fail("tx-failed", { hash: r.hash });
  return { hash: r.hash, block: rc.blockNumber };
}

// ---------- Gezgin bağlantıları
export function explorerTx(net, chain, id) { const C = chainOf(net, chain); return C.tx + id + (C.q || "") }
export function explorerAcct(net, chain, a) { const C = chainOf(net, chain); return C.acct + a + (C.q || "") }
