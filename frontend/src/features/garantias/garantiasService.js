// Servicio de Ventas & Garantías (Tareas 8, 13 y 14 del plan). Reutiliza el
// envoltorio de RPC de registroService: mismos códigos de error del repo.
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
