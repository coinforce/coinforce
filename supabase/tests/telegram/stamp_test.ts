// İşlem butonlarının oturum sürümü damgası: deno test supabase/tests/telegram/
import { stamp, unstamp } from "../../functions/telegram-notify/trade.ts";

function eq(a: unknown, b: unknown, msg = "") {
  const x = JSON.stringify(a), y = JSON.stringify(b);
  if (x !== y) throw new Error(`${msg} beklenen ${y}, gelen ${x}`);
}

Deno.test("damga: yalnızca işlem butonlarına sürüm eklenir", () => {
  const kb = {
    inline_keyboard: [
      [{ text: "10 USDT", callback_data: "x:mb:BTC:10" }, { text: "Menü", callback_data: "m" }],
      [{ text: "Uygulama", url: "https://example.org" }],
    ],
  };
  eq(stamp(kb, 7), {
    inline_keyboard: [
      [{ text: "10 USDT", callback_data: "x:mb:BTC:10:v7" }, { text: "Menü", callback_data: "m" }],
      [{ text: "Uygulama", url: "https://example.org" }],
    ],
  });
});

Deno.test("damga: sürüm yoksa işlem butonları gösterilmez, boş satır atılır", () => {
  const kb = { inline_keyboard: [[{ text: "Al", callback_data: "x:mb:BTC:10" }], [{ text: "Menü", callback_data: "m" }]] };
  eq(stamp(kb, undefined), { inline_keyboard: [[{ text: "Menü", callback_data: "m" }]] });
});

Deno.test("damga: 64 bayt sınırını aşacak buton gösterilmez", () => {
  const long = "x:fo:ABCDEFGHIJKLMNOPQRST:L:100:" + "9".repeat(30);
  eq(stamp({ inline_keyboard: [[{ text: "a", callback_data: long }]] }, 12), { inline_keyboard: [] });
});

Deno.test("damga çözme", () => {
  eq(unstamp("x:mb:BTC:10:v7"), { data: "x:mb:BTC:10", version: 7 });
  eq(unstamp("x:fc:4b1d6c1e-0b55-4a8e-9c1f-3c2a7c9d1e2f:v12"), { data: "x:fc:4b1d6c1e-0b55-4a8e-9c1f-3c2a7c9d1e2f", version: 12 });
  eq(unstamp("x:mb:BTC:10"), null);          // damgasız (eski) buton
  eq(unstamp("x:mb:V12:10"), null);          // sembol içindeki büyük V damga sayılmaz
  eq(unstamp("x:mb:BTC:10:vx"), null);
});
