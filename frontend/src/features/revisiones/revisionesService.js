// Servicio de revisiones (Tarea 21 del plan): lectura de `revisiones` por
// registro y anexo vía la RPC `registrar_revision`. NADIE edita ni borra.
import { supabase } from "../../lib/supabaseClient.js";

function mapearError(err) {
  if (err?.code === "42501") return { ok: false, codigo: "SIN_PERMISO", mensaje: err.message ?? "" };
  if (err?.code === "401" || err?.status === 401) {
    return { ok: false, codigo: "SESION_VENCIDA", mensaje: "Tu sesión venció: vuelve a entrar para continuar" };
  }
  return { ok: false, codigo: "DESCONOCIDO", mensaje: err?.message ?? "Error inesperado" };
}

export async function listarRevisiones(registroId) {
  try {
    const { data, error } = await supabase
      .from("revisiones")
      .select("id, tipo, revisado_por, revisado_en, checklist, resultado, observaciones")
      .eq("registro_id", registroId)
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

export async function registrarRevision(registroId, { tipo, checklist, observaciones }) {
  try {
    const { data, error } = await supabase.rpc("registrar_revision", {
      p_registro_id: registroId,
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