/**
 * Lectura y escritura de órdenes.
 *
 * Lectura: `v_ordenes_tablero` (security_invoker) + `kpis_tablero()`
 * (SECURITY INVOKER) -- ninguna filtra nada por su cuenta; lo que llega es
 * exactamente lo que la RLS del usuario deja ver (ADR-007).
 *
 * Escritura: `crear_orden()`. Toda operación de escritura de este módulo
 * devuelve `{ ok: true, datos }` o `{ ok: false, error: { codigo, mensaje } }`
 * -- ningún componente lee el mensaje crudo de PostgREST (§5 del spec).
 */
import { supabase } from "../../../lib/supabaseClient.js";

const COLUMNAS_BUSQUEDA = [
  "numero_orden",
  "cliente",
  "documento",
  "equipo",
  "numero_serie",
  "numero_factura",
];

/** No es una defensa contra inyección SQL -- PostgREST parametriza -- es
    para no romper la gramática de `.or()` con una coma o un paréntesis que
    el usuario tenga en la mano (§5.1 del spec). */
function sanearTermino(termino) {
  return termino.replace(/[(),*]/g, " ");
}

/** Fila de `v_ordenes_tablero` -> la forma que ya esperan TablaOrdenes y
    PanelVencimientos, sin tocar esos componentes. */
function normalizarFila(fila) {
  return {
    id: fila.id,
    numero: fila.numero_orden,
    cliente: fila.cliente,
    documento: fila.documento,
    equipo: fila.equipo,
    serie: fila.numero_serie,
    estado: fila.estado,
    estadoNombre: fila.estado_nombre,
    cobertura: fila.cobertura,
    prioridad: fila.prioridad,
    ingreso: fila.fecha_ingreso,
    venceEl: fila.garantia_vence_el,
    slaVenceEl: fila.sla_vence_el,
  };
}

export async function consultarOrdenes({
  estado = "TODAS",
  termino = "",
  pagina = 0,
  porPagina = 25,
} = {}) {
  let consulta = supabase
    .from("v_ordenes_tablero")
    .select("*", { count: "exact" })
    .order("fecha_ingreso", { ascending: false })
    .range(pagina * porPagina, pagina * porPagina + porPagina - 1);

  if (estado !== "TODAS") consulta = consulta.eq("estado", estado);

  const t = sanearTermino(String(termino ?? "").trim());
  if (t.length > 0) {
    consulta = consulta.or(COLUMNAS_BUSQUEDA.map((c) => `${c}.ilike.%${t}%`).join(","));
  }

  const { data, error, count } = await consulta;
  if (error) throw error;
  return { ordenes: (data ?? []).map(normalizarFila), total: count ?? 0 };
}

/** Recuento de órdenes por estado, para las píldoras de CU-03.
    `codigos` incluye `"TODAS"` si se quiere ese recuento también. N
    consultas `head: true` -- al volumen de un taller es irrelevante; si
    algún día duele, se agrega una vista agregada sin tocar la interfaz. */
export async function contarPorEstado(codigos) {
  const entradas = await Promise.all(
    codigos.map(async (codigo) => {
      let consulta = supabase
        .from("v_ordenes_tablero")
        .select("*", { count: "exact", head: true });
      if (codigo !== "TODAS") consulta = consulta.eq("estado", codigo);
      const { count, error } = await consulta;
      if (error) throw error;
      return [codigo, count ?? 0];
    })
  );
  return Object.fromEntries(entradas);
}

export async function consultarKpis() {
  const { data, error } = await supabase.rpc("kpis_tablero");
  if (error) throw error;
  // Una función SQL que retorna TABLE(...) de un solo registro llega como
  // un array de una fila.
  return Array.isArray(data) ? data[0] : data;
}

export async function consultarPorVencer({ dias = 30 } = {}) {
  const hoy = new Date().toISOString().slice(0, 10);
  const limite = new Date(Date.now() + dias * 86_400_000).toISOString().slice(0, 10);

  const { data, error } = await supabase
    .from("v_ordenes_tablero")
    .select("id, cliente, numero_serie, equipo, garantia_vence_el, cobertura")
    .eq("cobertura", "EN_GARANTIA")
    .gte("garantia_vence_el", hoy)
    .lte("garantia_vence_el", limite)
    .order("garantia_vence_el", { ascending: true });

  if (error) throw error;
  return (data ?? []).map((f) => ({
    id: f.id,
    cliente: f.cliente,
    serie: f.numero_serie,
    equipo: f.equipo,
    venceEl: f.garantia_vence_el,
  }));
}

/** Único sitio de la app que conoce los códigos de error de Postgres/
    PostgREST y los traduce a algo que se puede mostrar (§5, igual que
    `authService.js` con los errores de Auth). */
function traducirError(error) {
  const codigo = error?.code ?? "DESCONOCIDO";
  const mapa = {
    "42501": "Tu rol no puede registrar órdenes.",
    "22023": "Faltan datos del cliente o del equipo.",
    "23514": "Alguno de los datos no cumple las reglas del formulario (revisa fechas, meses y plazos).",
    "23505": "Ya existe un registro con esos datos.",
  };
  return { codigo, mensaje: mapa[codigo] ?? "No se pudo completar la operación. Intenta de nuevo." };
}

/**
 * Alta atómica de una orden. `cliente` y `producto` son objetos de la forma
 * `{ id }` (existente) o `{ nuevo: {...} }` (a crear en la misma
 * transacción) -- exactamente uno de los dos por cada uno, igual que exige
 * `crear_orden()` (ADR-009).
 */
export async function crearOrden({
  fechaCompra,
  fallaReportada,
  cliente,
  producto,
  numeroSerie,
  numeroFactura,
  accesorios,
  prioridad = "NORMAL",
  tipoGarantia = "ESTANDAR",
  mesesOverride = null,
  slaDias = 5,
  tecnicoId = null,
}) {
  const { data, error } = await supabase.rpc("crear_orden", {
    p_fecha_compra: fechaCompra,
    p_falla_reportada: fallaReportada,
    p_cliente_id: cliente?.id ?? null,
    p_cliente_nuevo: cliente?.nuevo ?? null,
    p_producto_id: producto?.id ?? null,
    p_producto_nuevo: producto?.nuevo ?? null,
    p_numero_serie: numeroSerie || null,
    p_numero_factura: numeroFactura || null,
    p_accesorios: accesorios || null,
    p_prioridad: prioridad,
    p_tipo_garantia: tipoGarantia,
    p_meses_override: mesesOverride,
    p_sla_dias: slaDias,
    p_tecnico_id: tecnicoId,
  });

  if (error) return { ok: false, error: traducirError(error) };

  const fila = Array.isArray(data) ? data[0] : data;
  return {
    ok: true,
    datos: {
      ordenId: fila.orden_id,
      numeroOrden: fila.numero_orden,
      consultaToken: fila.consulta_token,
      cobertura: fila.cobertura,
      venceEl: fila.vence_el,
      clienteId: fila.cliente_id,
      productoId: fila.producto_id,
    },
  };
}
