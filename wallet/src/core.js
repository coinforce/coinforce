/*! COINFORCE Web3 cüzdan çekirdeği (saklamasız / non-custodial)
 * Kurtarma ifadesi ve özel anahtarlar yalnızca kullanıcının cihazında üretilir ve şifreli saklanır;
 * bu dosya hiçbir anahtarı, ifadeyi ya da şifreyi ağ üzerinden göndermez. Ağ istekleri yalnızca
 * herkese açık blokzincir RPC uçlarına (bakiye okuma, simülasyon, işlem yayınlama) ve takas teklifi için
 * Jupiter (api.jup.ag) ile KyberSwap (aggregator-api.kyberswap.com) uçlarına yapılır; bunlara yalnızca
 * herkese açık adres ve tutar gider. Takas işlemleri imzadan önce simülasyonla denetlenir.
 * Paketlenen kütüphaneler (hepsi MIT lisanslı): ethers 6.17.0, @solana/web3.js 1.98.4,
 * @scure/bip39 2.4.0, @noble/hashes 2.4.0 (ve bağımlılıkları). Lisans metinleri: wallet/LICENSES.txt
 */
import { generateMnemonic, mnemonicToSeedSync, validateMnemonic } from "@scure/bip39";
import { wordlist } from "@scure/bip39/wordlists/english.js";
import { hmac } from "@noble/hashes/hmac.js";
import { sha512 } from "@noble/hashes/sha2.js";
import { HDNodeWallet, JsonRpcProvider, Contract, Interface, Network, isAddress, getAddress, parseUnits, formatUnits } from "ethers";
import { Connection, PublicKey, Keypair, SystemProgram, TransactionInstruction, TransactionMessage, VersionedTransaction, ComputeBudgetProgram, AddressLookupTableAccount } from "@solana/web3.js";

export const VERSION = "1.1.0";
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
    sol: { id: "sol", name: "Solana", sym: "SOL", dec: 9, rpc: ["https://api.mainnet-beta.solana.com", "https://solana-rpc.publicnode.com"], rpcTx: ["https://solana-rpc.publicnode.com", "https://api.mainnet-beta.solana.com"], tx: "solscan.io/tx/", acct: "solscan.io/account/", q: "",
      holdings: true, mints: { EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v: "USDC", Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB: "USDT", DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263: "BONK",
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
function solRows(C, lam, list) {   // list: [{acct, mint, prog, dec, raw(BigInt), frozen}]
  const rows = [{ net: "sol", netName: C.name, sym: "SOL", name: "Solana", dec: 9, raw: String(lam), native: true }], by = {};
  for (const a of list) {
    if (a.raw === 0n || a.frozen) continue; const cur = by[a.mint];
    if (!cur) by[a.mint] = { net: "sol", netName: C.name, mint: a.mint, prog: a.prog, dec: a.dec, raw: a.raw, acct: a.acct, acctRaw: a.raw };
    else { cur.raw += a.raw; if (a.raw > cur.acctRaw) { cur.acct = a.acct; cur.acctRaw = a.raw } }
  }
  for (const r of Object.values(by)) { const sym = C.mints[r.mint] || null; rows.push(Object.assign(r, { sym, name: sym, raw: String(r.raw), acctRaw: String(r.acctRaw) })) }
  return rows;
}
async function solBalances(C, owner) {
  const pk = new PublicKey(owner);
  try {
    return await withRpc(C.rpc, async u => {
      const cn = solConn(u), [lam, t1, t2] = await Promise.all([cn.getBalance(pk), cn.getParsedTokenAccountsByOwner(pk, { programId: new PublicKey(TOKEN) }), cn.getParsedTokenAccountsByOwner(pk, { programId: new PublicKey(TOKEN22) })]), list = [];
      for (const [arr, prog] of [[t1.value, TOKEN], [t2.value, TOKEN22]]) for (const a of arr) {
        const info = a.account.data && a.account.data.parsed && a.account.data.parsed.info, amt = info && info.tokenAmount; if (!amt) continue;
        list.push({ acct: a.pubkey.toBase58(), mint: info.mint, prog, dec: amt.decimals, raw: BigInt(amt.amount), frozen: info.state === "frozen" });
      }
      return solRows(C, lam, list);
    });
  } catch (e) {
    if (C.holdings) {   // yedek: Jupiter bakiye servisi (herkese açık adres)
      try {
        const j = await getJSON(`${JUP_API}/ultra/v1/holdings/${owner}`), list = [];
        if (j && j.amount != null && j.tokens) { for (const [mint, arr] of Object.entries(j.tokens)) for (const a of arr || []) if (a.programId === TOKEN || a.programId === TOKEN22) list.push({ acct: a.account, mint, prog: a.programId, dec: +a.decimals, raw: BigInt(a.amount), frozen: !!a.isFrozen });
          return solRows(C, BigInt(j.amount), list) }
      } catch (e2) {}
    }
    const lam = await withRpc(C.rpcTx || C.rpc, u => solConn(u).getBalance(pk));
    const rows = solRows(C, lam, []); rows.partial = true; return rows;
  }
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
  if (addrs && addrs.sol) jobs.push(solBalances(N.sol, addrs.sol).then(r => { list.push(...r); if (r.partial) errs.push({ net: "sol", msg: "tokens" }) }, e => errs.push({ net: "sol", msg: String(e && e.message || e) })));
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
  const C = NETS[net].sol, A = solAddr(to); raw = BigInt(raw || 0); const RPCS = C.rpcTx || C.rpc;
  if (!A.ok) throw fail("bad-address");
  if (!A.onCurve) throw fail("off-curve");
  if (A.addr === from) throw fail("self");
  if (max && !asset.native) raw = BigInt(asset.acctRaw);
  if (!max && raw <= 0n) throw fail("bad-amount");
  if (!asset.native && raw > BigInt(asset.acctRaw)) throw fail("insufficient");
  return withRpc(RPCS, async u => {
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
  const cn = solConn((C.rpcTx || C.rpc)[0]), ixs = [ComputeBudgetProgram.setComputeUnitLimit({ units: plan.units }), ComputeBudgetProgram.setComputeUnitPrice({ microLamports: plan.price }),
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

// =====================================================================================================
// ---------- Takas (zincir üstü). Solana: Jupiter /swap/v2/build (Metis yönlendirme, Jupiter ücreti yok; işlemi biz kurarız).
// EVM: KyberSwap Aggregator. Her iki tarafta da imzadan ÖNCE simülasyonla bakiye değişiklikleri denetlenir; beklenmeyen bir
// çıkış, sahiplik/harcama izni değişikliği ya da eksik çıktı varsa işlem imzalanmaz.
export const JUP_API = "https://api.jup.ag", KYBER_API = "https://aggregator-api.kyberswap.com";
export const WSOL = "So11111111111111111111111111111111111111112", EVM_NATIVE = "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE";
const KYBER_CHAIN = { eth: "ethereum", bsc: "bsc", base: "base" };
const KYBER_ROUTERS = ["0x6131B5fae19EA4f9D964eAc0408E4408b66337b5", "0x6868d319c8c9a78f7d39dc3602c5c917315132d7"].map(a => a.toLowerCase());
const CB = "ComputeBudget111111111111111111111111111111", SYS = "11111111111111111111111111111111";
const SAFE_PROGS = new Set([CB, SYS, TOKEN, TOKEN22, ATA]);
const b64u8 = s => Uint8Array.from(atob(s), c => c.charCodeAt(0));
const ERC20X = new Interface(["function balanceOf(address) view returns (uint256)", "function allowance(address,address) view returns (uint256)", "function approve(address,uint256) returns (bool)",
  "function decimals() view returns (uint8)", "function symbol() view returns (string)", "function name() view returns (string)",
  "event Transfer(address indexed from, address indexed to, uint256 value)", "event Approval(address indexed owner, address indexed spender, uint256 value)"]);
async function getJSON(url, opt) {
  const ctl = new AbortController(), t = setTimeout(() => ctl.abort(), 15000);
  try {
    const r = await fetch(url, Object.assign({ signal: ctl.signal }, opt || {})), j = await r.json().catch(() => null);
    if (r.status === 429) throw fail("rate-limited");
    if (!r.ok) throw fail(r.status === 400 || r.status === 404 || r.status === 422 ? "no-route" : "quote-failed", { status: r.status, detail: j && (j.error || j.message || j.errorMessage) || r.statusText });
    return j;
  } catch (e) { if (e && e.userFacing) throw e; throw fail("quote-net", { detail: String(e && e.message || e) }) } finally { clearTimeout(t) }
}
// SPL token hesabı (Token ve Token-2022 temel düzeni, ilk 165 bayt)
function parseTA(b) {
  if (!b || b.length < 165) return null; const dv = new DataView(b.buffer, b.byteOffset, b.byteLength);
  return { mint: new PublicKey(b.slice(0, 32)).toBase58(), owner: new PublicKey(b.slice(32, 64)).toBase58(), amount: dv.getBigUint64(64, true),
    delegate: dv.getUint32(72, true) ? new PublicKey(b.slice(76, 108)).toBase58() : null, close: dv.getUint32(129, true) ? new PublicKey(b.slice(133, 165)).toBase58() : null };
}
const accData = a => !a ? null : a.data instanceof Uint8Array ? a.data : Array.isArray(a.data) ? b64u8(a.data[0]) : null;

// ---- Solana
export async function solTokenInfo(mints) {   // zincirden: hangi token programı, kaç ondalık (Mint düzeninde 44. bayt)
  const N = NETS.main.sol; return withRpc(N.rpcTx, async u => {
    const r = await solConn(u).getMultipleAccountsInfo(mints.map(m => new PublicKey(m))), out = {};
    mints.forEach((m, i) => { const a = r[i]; if (!a) return; const o = a.owner.toBase58(); if ((o === TOKEN || o === TOKEN22) && a.data.length >= 82) out[m] = { prog: o, dec: a.data[44] } }); return out;
  });
}
export async function solSwapQuote({ from, inMint, outMint, raw, slippageBps }) {
  if (inMint === outMint) throw fail("same-token");
  if (!(BigInt(raw) > 0n)) throw fail("bad-amount");
  const q = new URLSearchParams({ inputMint: inMint, outputMint: outMint, amount: String(raw), taker: from, slippageBps: String(Math.round(slippageBps)), computeUnitPricePercentile: "high", maxAccounts: "48" });
  const r = await getJSON(`${JUP_API}/swap/v2/build?${q}`);
  if (!r || !r.swapInstruction || !r.outAmount) throw fail("no-route", { detail: r && (r.error || r.errorMessage) });
  const pi = r.priceImpact != null ? +r.priceImpact : r.priceImpactPct != null ? +r.priceImpactPct * 100 : null;
  return { chain: "sol", at: Date.now(), from, inMint, outMint, raw: String(raw), slippageBps, inAmount: String(r.inAmount), outAmount: String(r.outAmount), minOut: String(r.otherAmountThreshold),
    priceImpact: isFinite(pi) ? pi : null, route: [...new Set((r.routePlan || []).map(x => x.swapInfo && x.swapInfo.label).filter(Boolean))], resp: r };
}
function solSwapParts(q) {
  const r = q.resp, extra = [...(r.setupInstructions || []), ...(r.cleanupInstruction ? [r.cleanupInstruction] : []), ...(r.otherInstructions || [])];
  for (const j of extra) if (!SAFE_PROGS.has(j.programId)) throw fail("route-unsupported", { detail: j.programId });
  for (const j of [...extra, r.swapInstruction]) for (const a of j.accounts || []) if (a.isSigner && a.pubkey !== q.from) throw fail("route-unsupported", { detail: "signer" });
  const ix = j => new TransactionInstruction({ programId: new PublicKey(j.programId), keys: (j.accounts || []).map(a => ({ pubkey: new PublicKey(a.pubkey), isSigner: !!a.isSigner, isWritable: !!a.isWritable })), data: b64u8(j.data || "") });
  let price = 0;
  for (const j of r.computeBudgetInstructions || []) { if (j.programId !== CB) continue; const d = b64u8(j.data); if (d[0] === 3 && d.length >= 9) price = Number(new DataView(d.buffer).getBigUint64(1, true)) }
  const alts = Object.entries(r.addressesByLookupTableAddress || {}).map(([k, a]) => new AddressLookupTableAccount({ key: new PublicKey(k),
    state: { deactivationSlot: BigInt("18446744073709551615"), lastExtendedSlot: 0, lastExtendedSlotStartIndex: 0, authority: undefined, addresses: a.map(x => new PublicKey(x)) } }));
  return { ixs: [...(r.setupInstructions || []), r.swapInstruction, ...(r.cleanupInstruction ? [r.cleanupInstruction] : []), ...(r.otherInstructions || [])].map(ix), alts, price };
}
// Simülasyon öncesi/sonrası hesap durumlarını karşılaştıran saf denetim (test edilebilir). pre/post: [{lamports, owner, data(Uint8Array)}|null]
export function guardCheck(q, keys, pre, post) {
  const L0 = BigInt(pre[0] ? pre[0].lamports : 0), L1 = BigInt(post[0] ? post[0].lamports : 0);
  if (post[0] && post[0].owner !== SYS) throw fail("guard", { detail: "wallet-owner" });
  let inD = 0n, outD = 0n, rent = 0n;
  for (let i = 1; i < keys.length; i++) {
    const a0 = pre[i] ? parseTA(pre[i].data) : null, a1 = post[i] ? parseTA(post[i].data) : null;
    if (!a0 && a1) rent += BigInt(post[i].lamports || 0);
    const m = (a1 || a0 || {}).mint; if (!m) continue;
    if (a1 && a1.owner !== q.from) throw fail("guard", { detail: "token-owner" });
    if (a1 && a1.delegate && (!a0 || a0.delegate !== a1.delegate)) throw fail("guard", { detail: "delegate" });
    if (a1 && a1.close && (!a0 || a0.close !== a1.close)) throw fail("guard", { detail: "close-authority" });
    const d = (a1 ? a1.amount : 0n) - (a0 ? a0.amount : 0n);
    if (m === q.inMint && m !== WSOL) inD += d; else if (m === q.outMint && m !== WSOL) outD += d;
    else if (d < 0n && !(m === WSOL && (q.inMint === WSOL || q.outMint === WSOL))) throw fail("guard", { detail: "other-token" });
  }
  const raw = BigInt(q.raw), minOut = BigInt(q.minOut), feeMax = 3000000n + rent, dL = L1 - L0;   // ağ + öncelik ücreti (≤0,001) + pay; yeni açılan hesapların kirası ayrıca
  if (q.inMint !== WSOL && -inD > raw) throw fail("guard", { detail: "in-amount" });
  if (q.outMint !== WSOL && outD < minOut) throw fail("guard", { detail: "out-amount" });
  if (q.inMint === WSOL) { if (-dL > raw + feeMax) throw fail("guard", { detail: "sol-spent" }) }
  else if (q.outMint === WSOL) { if (dL < minOut - feeMax) throw fail("guard", { detail: "sol-received" }) }
  else if (-dL > feeMax) throw fail("guard", { detail: "sol-fee" });
  return { inD, outD, dL };
}
const accN = a => a ? { lamports: a.lamports, owner: typeof a.owner === "string" ? a.owner : a.owner.toBase58(), data: accData(a) } : null;
async function solGuard(cn, msg, q, watch) {
  const keys = [q.from, ...watch], pre = await cn.getMultipleAccountsInfo(keys.map(a => new PublicKey(a)), "confirmed");
  const sim = await cn.simulateTransaction(new VersionedTransaction(msg), { sigVerify: false, replaceRecentBlockhash: true, commitment: "confirmed", accounts: { encoding: "base64", addresses: keys } });
  if (sim.value.err) throw fail("sim-failed", { detail: JSON.stringify(sim.value.err), logs: (sim.value.logs || []).slice(-8) });
  const g = guardCheck(q, keys, pre.map(accN), (sim.value.accounts || []).map(accN));
  return Object.assign(g, { units: sim.value.unitsConsumed || 0 });
}
const solSwapMsg = (from, bh, units, price, ixs, alts) => new TransactionMessage({ payerKey: new PublicKey(from), recentBlockhash: bh,
  instructions: [ComputeBudgetProgram.setComputeUnitLimit({ units }), ComputeBudgetProgram.setComputeUnitPrice({ microLamports: price }), ...ixs] }).compileToV0Message(alts);
// Plan: işlemi kur, simüle et, denetle. İmza YOK.  userAccts: kullanıcının izlenecek diğer token hesapları
export async function solSwapPlan(q, userAccts) {
  const N = NETS.main.sol; return withRpc(N.rpcTx, async u => {
    const cn = solConn(u), from = new PublicKey(q.from), { ixs, alts, price: p0 } = solSwapParts(q);
    const mints = [q.inMint, q.outMint].filter(m => m !== WSOL), info = mints.length ? await cn.getMultipleAccountsInfo(mints.map(m => new PublicKey(m))) : [], tk = {};
    mints.forEach((m, i) => { const a = info[i], o = a && a.owner.toBase58(); if (o !== TOKEN && o !== TOKEN22) throw fail("bad-mint"); tk[m] = { prog: o, dec: a.data[44] } });
    const ataIn = q.inMint !== WSOL ? ataOf(from, new PublicKey(q.inMint), tk[q.inMint].prog).toBase58() : null, ataOut = q.outMint !== WSOL ? ataOf(from, new PublicKey(q.outMint), tk[q.outMint].prog).toBase58() : null;
    const watch = [...new Set([ataIn, ataOut, ...(userAccts || [])].filter(Boolean))].slice(0, 60);
    const bal = BigInt(await cn.getBalance(from));
    if (q.inMint === WSOL && bal < BigInt(q.raw) + 10000n) throw fail("insufficient");
    const { blockhash } = await cn.getLatestBlockhash("confirmed");
    const g = await solGuard(cn, solSwapMsg(q.from, blockhash, 1400000, 0, ixs, alts), q, watch);
    const units = Math.min(1400000, Math.ceil(g.units * 1.2) + 3000), price = Math.max(0, Math.min(p0, Math.floor(1000000 * 1e6 / units)));   // öncelik ücreti en fazla 0,001 SOL
    const msg = solSwapMsg(q.from, blockhash, units, price, ixs, alts);
    if (new VersionedTransaction(msg).serialize().length > 1232) throw fail("tx-too-large");
    const fee = 5000 + Math.ceil(units * price / 1e6);
    return Object.assign({}, q, { units, price, fee: String(fee), watch, ataOut, inDec: q.inMint === WSOL ? 9 : tk[q.inMint].dec, outDec: q.outMint === WSOL ? 9 : tk[q.outMint].dec, simOut: String(q.outMint === WSOL ? g.dL : g.outD) });
  });
}
async function solConfirm(cn, sig, wire, lastValidBlockHeight) {
  for (let i = 0; i < 120; i++) {
    await sleep(1500);
    const s = (await cn.getSignatureStatuses([sig])).value[0];
    if (s && s.err) throw fail("tx-failed", { sig, detail: JSON.stringify(s.err) });
    if (s && (s.confirmationStatus === "confirmed" || s.confirmationStatus === "finalized")) return { sig, slot: s.slot };
    if (i % 3 === 2) { if ((await cn.getBlockHeight("confirmed")) > lastValidBlockHeight) throw fail("expired", { sig }); cn.sendRawTransaction(wire, { skipPreflight: true, maxRetries: 0 }).catch(() => {}) }
  }
  throw fail("timeout", { sig });
}
// İmzala ve gönder: son kez simüle edip denetler; teklif eskiyse (60 sn) durur.
export async function solSwapSend(plan, phrase, onStatus) {
  if (Date.now() - plan.at > 60000) throw fail("quote-expired");
  const kp = solKeypair(phrase); if (kp.publicKey.toBase58() !== plan.from) throw fail("wallet-mismatch");
  const N = NETS.main.sol; return withRpc(N.rpcTx, async u => {
    const cn = solConn(u), { ixs, alts } = solSwapParts(plan), { blockhash, lastValidBlockHeight } = await cn.getLatestBlockhash("confirmed");
    const msg = solSwapMsg(plan.from, blockhash, plan.units, plan.price, ixs, alts);
    onStatus && onStatus({ stage: "check" }); await solGuard(cn, msg, plan, plan.watch);
    const tx = new VersionedTransaction(msg); tx.sign([kp]);
    const wire = tx.serialize(), sig = await cn.sendRawTransaction(wire, { skipPreflight: true, maxRetries: 3 });
    onStatus && onStatus({ stage: "sent", sig });
    return solConfirm(cn, sig, wire, lastValidBlockHeight);
  });
}

// ---- EVM (KyberSwap)
export async function evmTokenInfo(chain, addr) {   // yapıştırılan kontrat için: sembol, ad, ondalık (zincirden)
  const C = chainOf("main", chain), A = evmAddr(addr); if (!A.ok) throw fail("bad-address");
  return withRpc(C.rpc, async u => { const t = new Contract(A.addr, ERC20X, evmProv(C, u)); const [s, n, d] = await Promise.all([t.symbol(), t.name().catch(() => ""), t.decimals()]); return { address: A.addr, symbol: String(s).slice(0, 16), name: String(n).slice(0, 40), decimals: Number(d) } });
}
export async function evmSwapQuote({ chain, from, tokenIn, tokenOut, raw }) {
  const k = KYBER_CHAIN[chain]; if (!k) throw fail("bad-net");
  const tin = tokenIn || EVM_NATIVE, tout = tokenOut || EVM_NATIVE; if (tin.toLowerCase() === tout.toLowerCase()) throw fail("same-token");
  if (!(BigInt(raw) > 0n)) throw fail("bad-amount");
  const j = await getJSON(`${KYBER_API}/${k}/api/v1/routes?${new URLSearchParams({ tokenIn: tin, tokenOut: tout, amountIn: String(raw), gasInclude: "true", excludeRFQSources: "true", origin: from })}`, { headers: { "x-client-id": "coinforce" } });
  const d = j && j.data; if (!d || !d.routeSummary || !d.routeSummary.amountOut) throw fail("no-route", { detail: j && j.message });
  if (!KYBER_ROUTERS.includes(String(d.routerAddress).toLowerCase())) throw fail("route-unsupported", { detail: d.routerAddress });
  const rs = d.routeSummary, iu = +rs.amountInUsd, ou = +rs.amountOutUsd;
  return { chain, at: Date.now(), from, tokenIn: tin, tokenOut: tout, raw: String(raw), outAmount: String(rs.amountOut), priceImpact: iu > 0 && ou > 0 ? Math.max(0, (iu - ou) / iu * 100) : null,
    gasUsd: +rs.gasUsd || null, route: [...new Set((rs.route || []).flat().map(x => x && x.exchange).filter(Boolean))], routeSummary: rs };
}
async function evmSimulate(p, q, d, minOut, approves) {
  const from = q.from.toLowerCase(), hex = v => "0x" + BigInt(v || 0).toString(16), calls = approves.map(v => ({ from: q.from, to: q.tokenIn, data: ERC20X.encodeFunctionData("approve", [d.routerAddress, v]) }));
  calls.push({ from: q.from, to: d.routerAddress, data: d.data, value: hex(d.transactionValue) });
  let r = null;
  try { r = await p.send("eth_simulateV1", [{ blockStateCalls: [{ calls: calls.map(c => ({ from: c.from, to: c.to, data: c.data, value: c.value || "0x0" })) }], traceTransfers: true, validation: false }, "latest"]) } catch (e) { r = null }
  if (r && r[0] && Array.isArray(r[0].calls)) {
    const res = r[0].calls, last = res[res.length - 1];
    if (res.some(x => x.status !== "0x1")) throw fail("sim-failed", { detail: last && last.error && last.error.message || "revert" });
    const TT = ERC20X.getEvent("Transfer").topicHash, AT = ERC20X.getEvent("Approval").topicHash, NAT = EVM_NATIVE.toLowerCase(), tin = q.tokenIn.toLowerCase(), tout = q.tokenOut.toLowerCase();
    let gotOut = 0n, spentIn = 0n;
    for (const c of res) for (const l of c.logs || []) {
      const addr = String(l.address).toLowerCase(), t0 = l.topics && l.topics[0];
      if (t0 === AT && l.topics.length >= 3 && ("0x" + l.topics[1].slice(26)).toLowerCase() === from) {
        if (addr !== tin || ("0x" + l.topics[2].slice(26)).toLowerCase() !== d.routerAddress.toLowerCase() || BigInt(l.data) > BigInt(q.raw)) throw fail("guard", { detail: "approval" }) }
      if (t0 !== TT || !l.topics || l.topics.length < 3) continue;
      const fa = ("0x" + l.topics[1].slice(26)).toLowerCase(), ta = ("0x" + l.topics[2].slice(26)).toLowerCase(), v = BigInt(l.data);
      if (fa === from) { if (addr === tin) spentIn += v; else throw fail("guard", { detail: "other-token" }) }
      if (ta === from && addr === tout) gotOut += v;
    }
    if (spentIn > BigInt(q.raw)) throw fail("guard", { detail: "in-amount" });
    if (gotOut < minOut) throw fail("guard", { detail: "out-amount" });
    return { mode: "simulateV1", gas: BigInt(last.gasUsed || 0) || null, gotOut };
  }
  if (approves.length) return { mode: "deferred", gas: null };   // onay gerekmiş ve RPC eth_simulateV1 desteklemiyor: takas, onaydan sonra eth_call ile denenir
  try { await p.call({ from: q.from, to: d.routerAddress, data: d.data, value: BigInt(d.transactionValue || 0) }) } catch (e) { throw fail("sim-failed", { detail: String(e && (e.shortMessage || e.message) || e) }) }
  return { mode: "call", gas: null };
}
export async function evmSwapPlan(q, slippageBps) {
  const C = chainOf("main", q.chain), k = KYBER_CHAIN[q.chain];
  const j = await getJSON(`${KYBER_API}/${k}/api/v1/route/build`, { method: "POST", headers: { "content-type": "application/json", "x-client-id": "coinforce" },
    body: JSON.stringify({ routeSummary: q.routeSummary, sender: q.from, recipient: q.from, origin: q.from, slippageTolerance: Math.round(slippageBps), deadline: Math.floor(Date.now() / 1000) + 1200, enableGasEstimation: false, source: "coinforce" }) });
  const d = j && j.data; if (!d || !d.data) throw fail("no-route", { detail: j && j.message });
  if (!KYBER_ROUTERS.includes(String(d.routerAddress).toLowerCase())) throw fail("route-unsupported", { detail: d.routerAddress });
  const nativeIn = q.tokenIn.toLowerCase() === EVM_NATIVE.toLowerCase(), raw = BigInt(q.raw);
  if (BigInt(d.amountIn) !== raw) throw fail("guard", { detail: "amountIn" });
  if (BigInt(d.transactionValue || 0) !== (nativeIn ? raw : 0n)) throw fail("guard", { detail: "value" });
  const minOut = BigInt(d.amountOut) * BigInt(10000 - Math.round(slippageBps)) / 10000n;
  return withRpc(C.rpc, async u => {
    const p = evmProv(C, u), [bal, fd] = await Promise.all([p.getBalance(q.from), p.getFeeData()]);
    let approves = [];
    if (!nativeIn) {
      const t = new Contract(q.tokenIn, ERC20X, p), [tb, al] = await Promise.all([t.balanceOf(q.from), t.allowance(q.from, d.routerAddress)]);
      if (tb < raw) throw fail("insufficient");
      if (al < raw) approves = al > 0n ? [0n, raw] : [raw];   // tam tutar kadar izin (sınırsız değil); USDT gibi tokenlar önce sıfırlamayı ister
    } else if (bal < raw) throw fail("insufficient");
    const sim = await evmSimulate(p, q, d, minOut, approves);
    const maxFee = fd.maxFeePerGas != null ? fd.maxFeePerGas : fd.gasPrice, gasSwap = (sim.gas || BigInt(d.gas || 350000)) * 13n / 10n, gasAppr = BigInt(approves.length) * 65000n;
    const fee = (gasSwap + gasAppr) * maxFee, need = fee + (nativeIn ? raw : 0n);
    if (bal < need) throw fail("insufficient-fee", { need: String(need), have: String(bal) });
    return Object.assign({}, q, { slippageBps, minOut: String(minOut), outAmount: String(d.amountOut), router: d.routerAddress, data: d.data, value: String(d.transactionValue || 0), approves: approves.map(String),
      gasSwap: String(gasSwap), fee: String(fee), eip1559: fd.maxFeePerGas != null, maxFeePerGas: String(maxFee), maxPriorityFeePerGas: fd.maxPriorityFeePerGas != null ? String(fd.maxPriorityFeePerGas) : null, sim: sim.mode, at: Date.now() });
  });
}
export async function evmSwapSend(plan, phrase, onStatus) {
  if (Date.now() - plan.at > 120000) throw fail("quote-expired");
  const C = chainOf("main", plan.chain); return withRpc(C.rpc, async u => {
    const p = evmProv(C, u), w = evmWallet(phrase).connect(p); if (w.address !== plan.from) throw fail("wallet-mismatch");
    const fd = await p.getFeeData(), mf = fd.maxFeePerGas != null ? fd.maxFeePerGas : fd.gasPrice;
    if (mf > BigInt(plan.maxFeePerGas) * 3n / 2n) throw fail("fee-changed");
    const fees = fd.maxFeePerGas != null ? { type: 2, maxFeePerGas: mf, maxPriorityFeePerGas: fd.maxPriorityFeePerGas } : { type: 0, gasPrice: mf };
    let nonce = await p.getTransactionCount(w.address, "pending");
    for (const v of plan.approves || []) {
      onStatus && onStatus({ stage: "approve" });
      const data = ERC20X.encodeFunctionData("approve", [plan.router, BigInt(v)]), gas = await p.estimateGas({ from: plan.from, to: plan.tokenIn, data });
      let r; try { r = await w.sendTransaction(Object.assign({ to: plan.tokenIn, data, gasLimit: gas * 13n / 10n, nonce: nonce++, chainId: C.chainId }, fees)) } catch (e) { throw fail("send-failed", { detail: String(e && (e.shortMessage || e.message) || e) }) }
      const rc = await r.wait(1, 180000); if (!rc || rc.status !== 1) throw fail("tx-failed", { hash: r.hash });
    }
    onStatus && onStatus({ stage: "check" });
    let gas; try { gas = await p.estimateGas({ from: plan.from, to: plan.router, data: plan.data, value: BigInt(plan.value) }) } catch (e) { throw fail("sim-failed", { detail: String(e && (e.shortMessage || e.message) || e) }) }
    const measured = plan.sim === "simulateV1", c2 = BigInt(plan.gasSwap) * (measured ? 2n : 4n), floor = measured ? 800000n : 2500000n, cap = c2 > floor ? c2 : floor, gl = gas * 13n / 10n;
    if (gl > cap) throw fail("gas-high", { est: String(gas), cap: String(cap), planGas: String(plan.gasSwap) });   // tahmin planın çok üstündeyse gönderme: yetersiz gazla gönderip ücret yakmaktansa dur
    let r; try { r = await w.sendTransaction(Object.assign({ to: plan.router, data: plan.data, value: BigInt(plan.value), gasLimit: gl, nonce: nonce++, chainId: C.chainId }, fees)) } catch (e) { throw fail("send-failed", { detail: String(e && (e.shortMessage || e.message) || e) }) }
    onStatus && onStatus({ stage: "sent", hash: r.hash });
    const rc = await r.wait(1, 180000); if (!rc || rc.status !== 1) throw fail("tx-failed", { hash: r.hash });
    let got = null; try { const TT = ERC20X.getEvent("Transfer").topicHash, me = plan.from.toLowerCase(); for (const l of rc.logs) if (l.topics[0] === TT && l.address.toLowerCase() === plan.tokenOut.toLowerCase() && ("0x" + l.topics[2].slice(26)).toLowerCase() === me) got = (got || 0n) + BigInt(l.data) } catch (e) {}
    return { hash: r.hash, got: got != null ? String(got) : null };
  });
}
