// Servicio del asistente de registro (Tarea 15 del plan).
// ÚNICO módulo (junto a los otros *Service) que habla con Supabase:
// los componentes nunca importan el cliente directo (patrón del repo).
// Toda función devuelve { ok: true, datos } o { ok: false, codigo, mensaje }.

import { supabase } from "../../lib/supabaseClient.js";

/** Mapeo único de errores → códigos del contrato (plan, interfaz de Task 15). */
function mapearError(err) {
  const codigo = err?.code ?? err?.error?.code;
  if (codigo === "42501") {
    return { ok: false, codigo: "SIN_PERMISO", mensaje: err.message ?? "" };
  }
  if (codigo === "401" || err?.status === 401) {
    return { ok: false, codigo: "SESION_VENCIDA", mensaje: "Tu sesión venció: vuelve a entrar para continuar" };
  }
  return { ok: false, codigo: "DESCONOCIDO", mensaje: err?.message ?? "Error inesperado" };
}

/** Envuelve una llamada RPC: un throw de red se convierte en SIN_CONEXION. */
async function rpc(nombre, params) {
  try {
    const { data, error } = await supabase.rpc(nombre, params);
    if (error) return mapearError(error);
    return { ok: true, datos: data };
  } catch (err) {
    if (err instanceof TypeError || String(err?.name ?? "").startsWith("Fetch")) {
      return { ok: false, codigo: "SIN_CONEXION", mensaje: "Sin conexión: el registro queda a salvo, reintenten cuando vuelva el internet" };
    }
    return { ok: false, codigo: "DESCONOCIDO", mensaje: err?.message ?? "Error inesperado" };
  }
}

export async function buscarEquipo(serial) {
  return rpc("buscar_equipo", { p_serial: serial });
}

/** Catálogo (marca → modelo) para el paso "serial nuevo". */
export async function listarProductos() {
  try {
    const { data, error } = await supabase
      .from("productos")
      .select("id, marca(nombre), modelo, categoria, meses_garantia")
      .eq("activo", true)
      .order("modelo");
    if (error) return mapearError(error);
    return { ok: true, datos: data ?? [] };
  } catch (err) {
    if (err instanceof TypeError || String(err?.name ?? "").startsWith("Fetch")) {
      return { ok: false, codigo: "SIN_CONEXION", mensaje: "Sin conexión" };
    }
    return { ok: false, codigo: "DESCONOCIDO", mensaje: err?.message ?? "Error inesperado" };
  }
}

export async function guardarCliente(datos) {
  return rpc("guardar_cliente", {
    p_tipo: datos.tipo,
    p_documento: datos.documento,
    p_nombre: datos.nombre,
    p_telefono: datos.telefono ?? null,
    p_email: datos.email ?? null,
    p_direccion: datos.direccion ?? null,
  });
}

export async function abrirOrden(payload) {
  return rpc("abrir_orden", {
    p_serial: payload.serial,
    p_producto_id: payload.productoId ?? null,
    p_cliente_id: payload.clienteId ?? null,
    p_falla: payload.falla,
    p_accesorios: payload.accesorios ?? null,
    p_tipo_soporte: payload.tipoSoporte ?? null,
    p_numero_soporte: payload.numeroSoporte ?? null,
    p_fecha_emision: payload.fechaEmision ?? null,
    p_plazo_dias: payload.plazoDias ?? null,
    p_vendedor: payload.vendedor ?? null,
    p_checklist: payload.checklist ?? null,
    p_observaciones: payload.observaciones ?? null,
    // Idempotencia: la misma clave devuelve el registro original (sin token).
    p_clave_envio: payload.claveEnvio ?? null,
  });
}

export async function registrarRevision(ordenId, { tipo, checklist, observaciones }) {
  return rpc("registrar_revision", {
    p_orden_id: ordenId,
    p_tipo: tipo,
    p_checklist: checklist ?? null,
    p_observaciones: observaciones ?? null,
  });
}

/** Búsqueda del titular por documento (cédula, RIF o pasaporte). */
export async function buscarCliente(documento) {
  try {
    const limpio = String(documento ?? "").replace(/[^0-9]/g, "");
    if (limpio.length < 5) return { ok: true, datos: null };
    const { data, error } = await supabase
      .from("clientes")
      .select("id, tipo_documento, documento, nombre, telefono, email")
      .eq("documento", limpio);
    if (error) return mapearError(error);
    return { ok: true, datos: data?.[0] ?? null };
  } catch (err) {
    if (err instanceof TypeError || String(err?.name ?? "").startsWith("Fetch")) {
      return { ok: false, codigo: "SIN_CONEXION", mensaje: "Sin conexión" };
    }
    return { ok: false, codigo: "DESCONOCIDO", mensaje: err?.message ?? "Error inesperado" };
  }
}

/** La cobertura SIEMPRE la calcula la base; el navegador solo pregunta. */
export async function previsualizarCobertura({ venceEl, fechaIngreso, checklist }) {
  const respuesta = await rpc("calcular_cobertura", {
    p_vence_el: venceEl ?? null,
    p_fecha_ingreso: fechaIngreso ?? null,
    p_checklist: checklist ?? null,
  });
  if (!respuesta.ok) return respuesta;
  // La anulación exige un MOTIVO que solo la base puede nombrar.
  if (respuesta.datos === "ANULADA_POR_USO") {
    const motivo = await rpc("motivo_anulacion", { p_checklist: checklist ?? null });
    return {
      ok: true,
      datos: {
        cobertura: respuesta.datos,
        motivo: motivo.ok ? motivo.datos : null,
      },
    };
  }
  return { ok: true, datos: { cobertura: respuesta.datos, motivo: null } };
}

const MAX_BYTES = 8 * 1024 * 1024;   // 8 MB (fotos y documentos)
const MIME_FOTO = ["image/jpeg", "image/png", "image/webp"];
const MIME_DOC = ["application/pdf", "image/jpeg", "image/png"];

/**
 * Sube un archivo al bucket privado y registra su fila en `adjuntos`.
 * Valida MIME y tamaño ANTES de subir (FORMATO_NO_ADMITIDO / LIMITE).
 */
export async function subirAdjunto(ordenId, archivo, { tipo, etiqueta }) {
  const mime = archivo?.type ?? "";
  if (tipo === "FOTO" && !MIME_FOTO.includes(mime)) {
    return { ok: false, codigo: "FORMATO_NO_ADMITIDO", mensaje: "Formato no admitido: para las fotos usa JPG, PNG o WEBP" };
  }
  if (tipo === "DOCUMENTO" && !MIME_DOC.includes(mime)) {
    return { ok: false, codigo: "FORMATO_NO_ADMITIDO", mensaje: "Formato no admitido: para los documentos usa PDF, JPG o PNG" };
  }
  if (!archivo || archivo.size > MAX_BYTES) {
    return { ok: false, codigo: "LIMITE", mensaje: "El archivo no puede pesar más de 8 MB" };
  }

  const ruta = `ordenes/${ordenId}/${archivo.name}`;
  try {
    const { error: errorSubida } = await supabase.storage.from("ordenes").upload(ruta, archivo);
    if (errorSubida) return mapearError(errorSubida);

    const { data, error } = await supabase
      .from("adjuntos")
      .insert({
        orden_id: ordenId,
        tipo,
        etiqueta: etiqueta ?? null,
        ruta,
        mime,
        bytes: archivo.size,
      });

    if (error) return mapearError(error);
    return { ok: true, datos: Array.isArray(data) ? data[0] : data };
  } catch (err) {
    if (err instanceof TypeError || String(err?.name ?? "").startsWith("Fetch")) {
      return { ok: false, codigo: "SIN_CONEXION", mensaje: "Sin conexión: vuelve a intentar la subida" };
    }
    return { ok: false, codigo: "DESCONOCIDO", mensaje: err?.message ?? "Error inesperado" };
  }
}