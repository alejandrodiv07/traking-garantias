// Servicio de Ventas & Garantías (Tareas 8, 13 y 14 del plan). Reutiliza el
// envoltorio de RPC de registroService: mismos códigos de error del repo.
import { supabase } from "../../lib/supabaseClient.js";
import { rpc } from "../registro/registroService.js";

/** Crea la garantía (el equipo) sin abrir orden. Devuelve la fila creada. */
export async function registrarGarantia({
  clienteId,
  productoId,
  serial,
  tipoSoporte,
  numeroSoporte,
  fechaEmision,
  plazoDias,
  origen = "VENTA",
}) {
  const r = await rpc("registrar_garantia", {
    p_cliente_id: clienteId,
    p_producto_id: productoId,
    p_serial: serial,
    p_tipo_soporte: tipoSoporte ?? null,
    p_numero_soporte: numeroSoporte ?? null,
    p_fecha_emision: fechaEmision ?? null,
    p_plazo_dias: plazoDias ?? null,
    p_origen: origen,
  });
  return r.ok ? { ok: true, datos: r.datos?.[0] ?? null } : r;
}

/** Busca por serial, cédula/RIF, factura u orden; lo que falta va en null. */
export async function buscarGarantia({ serial, documento, factura, orden } = {}) {
  return rpc("buscar_equipo", {
    p_serial: serial ?? null,
    p_documento: documento ?? null,
    p_factura: factura ?? null,
    p_orden: orden ?? null,
  });
}

/** Una fila por equipo (v_garantias), la que vence antes primero. */
export async function listarGarantias({ busqueda } = {}) {
  try {
    let q = supabase.from("v_garantias").select("*").order("vence_el", { ascending: true }).limit(200);
    const b = String(busqueda ?? "").trim().replace(/[*%,()]/g, "");
    if (b) {
      q = q.or(
        ["numero_serie", "titular", "documento", "numero_soporte"].map((c) => `${c}.ilike.*${b}*`).join(","),
      );
    }
    const { data, error } = await q;
    if (error) return { ok: false, codigo: error.code === "42501" ? "SIN_PERMISO" : "DESCONOCIDO", mensaje: error.message ?? "" };
    return { ok: true, datos: data ?? [] };
  } catch {
    return { ok: false, codigo: "SIN_CONEXION", mensaje: "Sin conexión" };
  }
}

/** Solo ADMIN/JEFE_SERVICIO (lo impone la base): ratifica o completa el soporte de compra. */
export async function confirmarCompra({ equipoId, tipoSoporte, numeroSoporte, fechaEmision, plazoDias }) {
  return rpc("confirmar_compra", {
    p_equipo_id: equipoId,
    p_tipo_soporte: tipoSoporte,
    p_numero_soporte: numeroSoporte,
    p_fecha_emision: fechaEmision,
    p_plazo_dias: plazoDias,
  });
}

/** Solo ADMIN/JEFE_SERVICIO: la compra no vale; las órdenes abiertas pasan a PAGO. */
export async function desestimarCompra({ equipoId, motivo }) {
  return rpc("desestimar_compra", { p_equipo_id: equipoId, p_motivo: motivo });
}
