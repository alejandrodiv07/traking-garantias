// Servicio del Inventario (catálogo de productos): única puerta a `marcas` y `productos`.
// Leer lo ve cualquier rol interno; crear, corregir y desactivar es de ADMIN y
// JEFE_SERVICIO (lo impone la RLS; la interfaz solo lo anticipa).
import { supabase } from "../../lib/supabaseClient.js";

function mapearError(err) {
  const codigo = err?.code;
  if (codigo === "42501") return { ok: false, codigo: "SIN_PERMISO", mensaje: "Solo ADMIN o JEFE_SERVICIO administran el catálogo" };
  if (codigo === "23505") return { ok: false, codigo: "DUPLICADO", mensaje: "Ya existe ese modelo para esa marca" };
  if (codigo === "23514") return { ok: false, codigo: "INVALIDO", mensaje: "Revisa los datos: la garantía va de 0 a 120 meses y el modelo hasta 80 caracteres" };
  return { ok: false, codigo: "DESCONOCIDO", mensaje: err?.message ?? "Error inesperado" };
}

function sinConexion(err) {
  if (err instanceof TypeError || String(err?.name ?? "").startsWith("Fetch")) {
    return { ok: false, codigo: "SIN_CONEXION", mensaje: "Sin conexión" };
  }
  return { ok: false, codigo: "DESCONOCIDO", mensaje: err?.message ?? "Error inesperado" };
}

/** Todo el catálogo (activos e inactivos), por marca y modelo: { id, marca, modelo, categoria, meses_garantia, activo }. */
export async function listarCatalogo() {
  try {
    const { data, error } = await supabase
      .from("productos")
      .select("id, marcas(nombre), modelo, categoria, meses_garantia, activo")
      .order("modelo")
      .limit(2000);
    if (error) return mapearError(error);
    const filas = (data ?? []).map(({ marcas, ...p }) => ({ ...p, marca: marcas?.nombre ?? "" }));
    filas.sort((a, b) => a.marca.localeCompare(b.marca) || a.modelo.localeCompare(b.modelo));
    return { ok: true, datos: filas };
  } catch (err) {
    return sinConexion(err);
  }
}

/** El id de la marca (existente, sin distinguir mayúsculas) o el de la recién creada. */
async function idMarca(nombre) {
  const limpio = nombre.trim();
  const escapado = limpio.replace(/[\\%_]/g, (c) => `\\${c}`);
  const { data, error } = await supabase.from("marcas").select("id").ilike("nombre", escapado).maybeSingle();
  if (error) return { error };
  if (data) return { id: data.id };
  const creada = await supabase.from("marcas").insert({ nombre: limpio }).select("id").single();
  return creada.error ? { error: creada.error } : { id: creada.data.id };
}

/** Agrega un modelo; si la marca no existe la crea. El tipo se guarda en mayúsculas, como el resto del catálogo. */
export async function crearProducto({ marca, modelo, categoria, meses }) {
  try {
    const m = await idMarca(marca);
    if (m.error) return mapearError(m.error);
    const { error } = await supabase.from("productos").insert({
      marca_id: m.id,
      modelo: modelo.trim(),
      categoria: categoria.trim().toUpperCase(),
      meses_garantia: Number(meses),
    });
    return error ? mapearError(error) : { ok: true, datos: null };
  } catch (err) {
    return sinConexion(err);
  }
}

/** Corrige el tipo y la garantía del fabricante de un modelo. */
export async function actualizarProducto(id, { categoria, meses }) {
  try {
    const { error } = await supabase
      .from("productos")
      .update({ categoria: categoria.trim().toUpperCase(), meses_garantia: Number(meses) })
      .eq("id", id);
    return error ? mapearError(error) : { ok: true, datos: null };
  } catch (err) {
    return sinConexion(err);
  }
}

/** Un modelo con garantías registradas no se borra (FK RESTRICT): se desactiva y deja de ofrecerse. */
export async function cambiarActivo(id, activo) {
  try {
    const { error } = await supabase.from("productos").update({ activo }).eq("id", id);
    return error ? mapearError(error) : { ok: true, datos: null };
  } catch (err) {
    return sinConexion(err);
  }
}
