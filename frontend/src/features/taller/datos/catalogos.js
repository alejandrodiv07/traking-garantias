/**
 * Catálogos que vienen de la base: estados, marcas, técnicos, y las dos
 * búsquedas asíncronas del formulario de alta (clientes, productos).
 *
 * Todo lo de aquí es de solo lectura vía PostgREST. La escritura del alta
 * (y de sus documentos) vive en `ordenes.js` y `documentos.js`.
 */
import { supabase } from "../../../lib/supabaseClient.js";

/**
 * Los estados activos de `estados_garantia`, en su columna `orden`.
 * CU-03: agregar un estado con un INSERT lo hace aparecer aquí sin tocar
 * React -- por eso este catálogo no se declara a mano en ningún lado más.
 */
export async function listarEstados() {
  const { data, error } = await supabase
    .from("estados_garantia")
    .select("codigo, nombre, orden, es_final")
    .eq("activo", true)
    .order("orden", { ascending: true });

  if (error) throw error;
  return data ?? [];
}

/** Autocompletado de clientes: nombre O documento, hasta 8 resultados. */
export async function buscarClientes(termino) {
  const t = String(termino ?? "").trim().replace(/[(),*]/g, " ");
  if (t.length < 2) return [];

  const { data, error } = await supabase
    .from("clientes")
    .select("id, tipo_documento, documento, nombre, telefono, email")
    .or(`nombre.ilike.%${t}%,documento.ilike.%${t}%`)
    .limit(8);

  if (error) throw error;
  return data ?? [];
}

/**
 * Autocompletado de productos: por modelo, hasta 8 resultados, con la marca
 * como dato desambiguador (§7.2 -- dos "Router X" son indistinguibles sin
 * saber de qué marca es cada uno).
 */
export async function buscarProductos(termino) {
  const t = String(termino ?? "").trim().replace(/[(),*]/g, " ");
  if (t.length < 2) return [];

  const { data, error } = await supabase
    .from("productos")
    .select("id, modelo, categoria, meses_garantia, marca_id, marcas(nombre)")
    .ilike("modelo", `%${t}%`)
    .eq("activo", true)
    .limit(8);

  if (error) throw error;
  return (data ?? []).map((p) => ({
    id: p.id,
    modelo: p.modelo,
    categoria: p.categoria,
    mesesGarantia: p.meses_garantia,
    marcaId: p.marca_id,
    marca: p.marcas?.nombre ?? "",
  }));
}

/** Marcas activas, para el selector que aparece al registrar un producto
    nuevo (crear_orden() exige un marca_id existente, nunca lo crea). */
export async function listarMarcas() {
  const { data, error } = await supabase
    .from("marcas")
    .select("id, nombre")
    .eq("activo", true)
    .order("nombre", { ascending: true });

  if (error) throw error;
  return data ?? [];
}

/** Perfiles con rol TECNICO y cuenta activa, para el selector "Técnico". */
export async function listarTecnicos() {
  const { data, error } = await supabase
    .from("profiles")
    .select("id, full_name")
    .eq("role", "TECNICO")
    .eq("is_active", true)
    .order("full_name", { ascending: true });

  if (error) throw error;
  return data ?? [];
}
