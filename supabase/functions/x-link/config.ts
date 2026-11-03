// x-link ayarları Supabase Secrets'tan okunur: X_CLIENT_ID, X_CLIENT_SECRET (gerekli); APP_URL, X_AUTH_URL, X_API_URL (isteğe bağlı).
export const cfg = (k: string): string => Deno.env.get(k) ?? "";
