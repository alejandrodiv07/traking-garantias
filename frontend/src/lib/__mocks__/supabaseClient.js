/**
 * Doble manual de `supabaseClient.js` para pruebas (`vi.mock` lo usa
 * automáticamente cuando un test llama a
 * `vi.mock("../../../lib/supabaseClient.js")` sin fábrica).
 *
 * El módulo real valida variables de entorno y llama a `createClient` al
 * cargarse -- justo lo que este doble evita, para que las pruebas no
 * necesiten `VITE_SUPABASE_URL`/`VITE_SUPABASE_ANON_KEY`.
 */
import { vi } from "vitest";

export const supabase = {
  from: vi.fn(),
  rpc: vi.fn(),
  storage: { from: vi.fn() },
};
