import "@testing-library/jest-dom/vitest";

// El cliente de Supabase exige URL y clave al importarse. Las pruebas
// JAMÁS hablan con una base real (cada suite simula el cliente o los
// servicios en su borde), así que si falta el .env.local (CI, otra
// máquina) se proveen valores de pantalla: no hay conexión posible.
import.meta.env.VITE_SUPABASE_URL ||= "http://sb.fake/para-pruebas";
import.meta.env.VITE_SUPABASE_ANON_KEY ||= "clave-anon-de-pruebas";