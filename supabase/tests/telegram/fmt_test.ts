// Ayrıştırma ve biçimlendirme birim testleri: deno test supabase/tests/telegram/
import { money, parseAmount, parseFutArgs, parseNum, parseSpotArgs, parseSymbol, pct, price, qty, signedMoney } from "../../functions/telegram-notify/fmt.ts";

function eq(a: unknown, b: unknown, msg = "") {
  const x = JSON.stringify(a), y = JSON.stringify(b);
  if (x !== y) throw new Error(`${msg} beklenen ${y}, gelen ${x}`);
}
const num = (s: string) => { const r = parseNum(s); return r.ok ? r.value : "ERR"; };

Deno.test("sayı: Türkçe ve İngilizce ondalık", () => {
  eq(num("100"), 100); eq(num("0,5"), 0.5); eq(num("0.5"), 0.5); eq(num("1.234,56"), 1234.56); eq(num("1,234.56"), 1234.56);
  eq(num("0,001"), 0.001); eq(num("0.001"), 0.001); eq(num("12,5"), 12.5); eq(num("1.000.000"), 1000000); eq(num("1000"), 1000);
  eq(num("65432.1"), 65432.1); eq(num("0,00001234"), 0.00001234);
});
Deno.test("sayı: belirsiz ve geçersiz yazımlar reddedilir", () => {
  eq(num("2.500"), "ERR"); eq(num("1,000"), "ERR"); eq(num("abc"), "ERR"); eq(num("1.2.3"), "ERR"); eq(num(""), "ERR"); eq(num("-5"), "ERR"); eq(num("1e5"), "ERR");
});
Deno.test("sembol", () => {
  eq(parseSymbol("btc"), "BTC"); eq(parseSymbol("BTC/USDT"), "BTC"); eq(parseSymbol("btcusdt"), "BTC"); eq(parseSymbol("$pepe"), "PEPE");
  eq(parseSymbol("usdt"), null); eq(parseSymbol("bt c"), null); eq(parseSymbol("<b>"), null);
});
Deno.test("tutar", () => {
  eq(parseAmount("%50", false), { ok: true, amount: { kind: "pct", value: 50 } });
  eq(parseAmount("25%", true), { ok: true, amount: { kind: "pct", value: 25 } });
  eq(parseAmount("100usdt", true), { ok: true, amount: { kind: "usdt", value: 100 } });
  eq(parseAmount("$100", true), { ok: true, amount: { kind: "usdt", value: 100 } });
  eq(parseAmount("0,01", true), { ok: true, amount: { kind: "qty", value: 0.01 } });
  eq(parseAmount("hepsi", true), { ok: true, amount: { kind: "all" } });
  eq(parseAmount("%150", false).ok, false);
});
Deno.test("spot komutları", () => {
  eq(parseSpotArgs(["BTC", "100"], "buy"), { symbol: "BTC", amount: { kind: "usdt", value: 100 }, type: "market", price: null });
  eq(parseSpotArgs(["btc", "100", "limit", "60000"], "buy"), { symbol: "BTC", amount: { kind: "usdt", value: 100 }, type: "limit", price: 60000 });
  eq(parseSpotArgs(["ETH", "50", "@2500,5"], "buy"), { symbol: "ETH", amount: { kind: "usdt", value: 50 }, type: "limit", price: 2500.5 });
  eq(parseSpotArgs(["BTC", "%50", "stop", "58000"], "sell"), { symbol: "BTC", amount: { kind: "pct", value: 50 }, type: "stop", price: 58000 });
  eq(parseSpotArgs(["BTC", "0,01"], "sell"), { symbol: "BTC", amount: { kind: "qty", value: 0.01 }, type: "market", price: null });
  eq(parseSpotArgs(["BTC", "hepsi"], "buy").amount, { kind: "pct", value: 100 });
  eq(!!parseSpotArgs(["BTC", "100", "limit"], "buy").error, true);
  eq(!!parseSpotArgs(["BTC", "100", "200"], "buy").error, true);
  eq(!!parseSpotArgs(["BTC", "2.500"], "buy").error, true);
});
Deno.test("vadeli komutları", () => {
  eq(parseFutArgs(["BTC", "100", "10x"]), { symbol: "BTC", margin: { kind: "usdt", value: 100 }, leverage: 10 });
  eq(parseFutArgs(["eth", "x5", "25"]), { symbol: "ETH", margin: { kind: "usdt", value: 25 }, leverage: 5 });
  eq(parseFutArgs(["SOL", "%10", "20x"]), { symbol: "SOL", margin: { kind: "pct", value: 10 }, leverage: 20 });
  eq(parseFutArgs(["SOL", "50", "3"]), { symbol: "SOL", margin: { kind: "usdt", value: 50 }, leverage: 3 });
  eq(!!parseFutArgs(["SOL", "hepsi", "3x"]).error, true);
  eq(parseFutArgs(["BTC", "100", "10x", "izole"]), { symbol: "BTC", margin: { kind: "usdt", value: 100 }, leverage: 10 });
});
Deno.test("desteklenmeyen emir türleri açıkça reddedilir", () => {
  const fut = (a: string[]) => parseFutArgs(a).error ?? "";
  for (const w of ["limit", "stop", "tp", "SL", "cross", "çapraz", "@60000"]) {
    eq(fut(["BTC", "100", "10x", w, "60000"]).includes("desteklenmiyor"), true, `vadeli ${w}`);
  }
  eq((parseSpotArgs(["BTC", "100", "tp", "80000"], "buy").error ?? "").includes("TP/SL desteklenmiyor"), true);
  eq((parseSpotArgs(["BTC", "hepsi", "sl", "50000"], "sell").error ?? "").includes("TP/SL desteklenmiyor"), true);
});
Deno.test("biçimlendirme", () => {
  eq(money(1234.5), "1.234,50"); eq(money(0.004), "0,00"); eq(signedMoney(-5), "−5,00"); eq(signedMoney(12.345), "+12,35");
  eq(price(65432.1), "$65.432,10"); eq(price(2.5), "$2,50"); eq(price(0.00001234), "$0,00001234"); eq(qty(0.001520000), "0,00152"); eq(pct(2.345), "+2,35%");
});
