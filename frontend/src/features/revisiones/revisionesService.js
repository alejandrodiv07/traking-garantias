// Servicio de revisiones (Tarea 21 del plan): lectura de `revisiones` por
// orden y anexo vía la RPC `registrar_revision`. NADIE edita ni borra.
import { supabase } from "../../lib/supabaseClient.js";

function mapearError(err) {
  if (err?.code === "42501") return { ok: false, codigo: "SIN_PERMISO", mensaje: err.message ?? "" };
  if (err?.code === "401" || err?.status === 401) {
    return { ok: false, codigo: "SESION_VENCIDA", mensaje: "Tu sesión venció: vuelve a entrar para continuar" };
  }
  return { ok: false, codigo: "DESCONOCIDO", mensaje: err?.message ?? "Error inesperado" };
}

export async function listarRevisiones(ordenId) {
  try {
    const { data, error } = await supabase
      .from("revisiones")
      // Embed por FK `revisiones.revisado_por → profiles.id`: el revisor
      // se ve por su nombre, no como UUID.
      .select("id, tipo, revisado_en, checklist, resultado, observaciones, revisor:revisado_por(full_name)")
      .eq("orden_id", ordenId)
      .order("revisado_en", { ascending: false });
    if (error) return mapearError(error);
    return { ok: true, datos: data ?? [] };
  } catch (err) {
    if (err instanceof TypeError || String(err?.name ?? "").startsWith("Fetch")) {
      return { ok: false, codigo: "SIN_CONEXION", mensaje: "Sin conexión" };
    }
    return { ok: false, codigo: "DESCONOCIDO", mensaje: err?.message ?? "Error inesperado" };
  }
}

export async function registrarRevision(ordenId, { tipo, checklist, observaciones }) {
  try {
    const { data, error } = await supabase.rpc("registrar_revision", {
      p_orden_id: ordenId,
      p_tipo: tipo,
      p_checklist: checklist ?? null,
      p_observaciones: observaciones ?? null,
    });
    if (error) return mapearError(error);
    return { ok: true, datos: Array.isArray(data) ? data[0] : data };
  } catch (err) {
    if (err instanceof TypeError || String(err?.name ?? "").startsWith("Fetch")) {
      return { ok: false, codigo: "SIN_CONEXION", mensaje: "Sin conexión" };
    }
    return { ok: false, codigo: "DESCONOCIDO", mensaje: err?.message ?? "Error inesperado" };
  }
}