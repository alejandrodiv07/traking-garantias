/**
 * ===========================================================================
 * DATOS DE DEMOSTRACIÓN — NADA DE ESTO SALE DE LA BASE TODAVÍA
 * ===========================================================================
 * Este fichero existe para que el tablero se pueda ver, revisar y discutir
 * antes de escribir una sola consulta. Es el ÚNICO sitio del módulo con datos
 * inventados: los componentes reciben todo por props y no saben de dónde
 * viene, así que el día que se conecte Supabase se sustituye este módulo por
 * un hook (`useOrdenes()`, `useKpis()`) y ningún componente cambia.
 *
 * Las formas de los objetos NO son libres: replican las columnas reales.
 *
 *   orden.numero    -> garantias.numero_orden   ('ORD-YYYY-NNNNNN', §6)
 *   orden.estado    -> garantias.estado         (FK a estados_garantia)
 *   orden.cobertura -> garantias.cobertura      (ENUM cobertura_garantia)
 *   orden.cliente   -> clientes.nombre + tipo_documento || documento
 *   orden.equipo    -> marcas.nombre || ' ' || productos.modelo
 *   orden.serie     -> garantias.numero_serie   (NULLABLE: hay órdenes sin serial)
 *   orden.ingreso   -> garantias.fecha_ingreso
 *   orden.venceEl   -> garantias.garantia_vence_el
 *
 * Se incluyen a propósito los casos incómodos que un mock bonito esconde y
 * que luego rompen la pantalla en producción: un nombre de cliente larguísimo,
 * una orden sin número de serie, una cobertura POR_DETERMINAR y estados de
 * los cuatro tonos.
 * ===========================================================================
 */

/** Fecha de referencia del mock, para que los "faltan N días" no caduquen. */
import { ESTADOS_TERMINALES } from "./dominio.js";

export const HOY = new Date("2026-09-07T12:00:00");

export const USUARIO_DEMO = Object.freeze({
  nombre: "Carlos Méndez",
  iniciales: "CM",
  rol: "Administración",
});

export const ORDENES = Object.freeze([
  {
    id: "1",
    numero: "ORD-2026-000142",
    cliente: "Comercializadora Andina C.A.",
    documento: "J-30589214-7",
    equipo: "Huawei EchoLife HG8245W5",
    serie: "RT5-8842-AA",
    estado: "EN_DIAGNOSTICO",
    cobertura: "EN_GARANTIA",
    ingreso: "2026-09-05",
    venceEl: "2026-09-10",
    tecnico: "Carlos Méndez",
  },
  {
    id: "2",
    numero: "ORD-2026-000141",
    cliente: "María Pérez",
    documento: "V-12345678",
    equipo: "ZTE ZXHN F660 GPON",
    serie: "GPN-4471-KM",
    estado: "RECIBIDO",
    cobertura: "POR_DETERMINAR",
    ingreso: "2026-09-05",
    venceEl: "2026-09-16",
    tecnico: null,
  },
  {
    id: "3",
    numero: "ORD-2026-000139",
    cliente: "Distribuidora El Faro de Occidente, C.A.",
    documento: "J-40551220-3",
    equipo: "TP-Link TL-SG1024D",
    serie: "SW24-0093-LM",
    estado: "REPARADO",
    cobertura: "FUERA_DE_GARANTIA",
    ingreso: "2026-09-04",
    venceEl: "2026-02-28",
    tecnico: "Ana Rondón",
  },
  {
    id: "4",
    numero: "ORD-2026-000137",
    cliente: "Luis Aguilar",
    documento: "V-19887654",
    equipo: "Nokia Beacon 1.1",
    serie: null,
    estado: "EN_REPARACION",
    cobertura: "EN_GARANTIA",
    ingreso: "2026-09-02",
    venceEl: "2026-09-25",
    tecnico: "Carlos Méndez",
  },
  {
    id: "5",
    numero: "ORD-2026-000136",
    cliente: "Telecom del Sur S.A.",
    documento: "J-31002948-1",
    equipo: "Genérico Fuente 12V 2A",
    serie: "PW90-7781-ZZ",
    estado: "EN_ESPERA_REPUESTO",
    cobertura: "EN_GARANTIA",
    ingreso: "2026-09-01",
    venceEl: "2026-10-04",
    tecnico: "Ana Rondón",
  },
  {
    id: "6",
    numero: "ORD-2026-000135",
    cliente: "Inversiones Delta 2020, C.A.",
    documento: "J-41200873-9",
    equipo: "Huawei OptiXstar EG8145V5",
    serie: "ONT-3390-PL",
    estado: "RECHAZADO_POR_CLIENTE",
    cobertura: "ANULADA_POR_USO",
    ingreso: "2026-08-31",
    venceEl: "2026-12-01",
    tecnico: "Ana Rondón",
  },
  {
    id: "7",
    numero: "ORD-2026-000132",
    cliente: "Ana Gutiérrez",
    documento: "V-20441123",
    equipo: "TP-Link RE550 Mesh",
    serie: "MX3-0561-BC",
    estado: "ENTREGADO",
    cobertura: "EN_GARANTIA",
    ingreso: "2026-08-29",
    venceEl: "2026-10-04",
    tecnico: "Carlos Méndez",
  },
  {
    id: "8",
    numero: "ORD-2026-000130",
    cliente: "Redes Caribe C.A.",
    documento: "J-29981145-0",
    equipo: "ZTE ZXHN H298A",
    serie: "MX3-9987-RM",
    estado: "IRREPARABLE",
    cobertura: "FUERA_DE_GARANTIA",
    ingreso: "2026-08-27",
    venceEl: "2026-01-19",
    tecnico: "Ana Rondón",
  },
]);

/**
 * Garantías por vencer. En la pantalla real:
 *   where garantia_vence_el between current_date and current_date + 30
 *     and estado not in ('ENTREGADO','ANULADO')
 *   order by garantia_vence_el
 */
export const POR_VENCER = Object.freeze([
  { id: "1", cliente: "Comercializadora Andina C.A.", serie: "RT5-8842-AA", equipo: "Huawei EchoLife HG8245W5", venceEl: "2026-09-10" },
  { id: "2", cliente: "María Pérez", serie: "GPN-4471-KM", equipo: "ZTE ZXHN F660 GPON", venceEl: "2026-09-16" },
  { id: "4", cliente: "Luis Aguilar", serie: null, equipo: "Nokia Beacon 1.1", venceEl: "2026-09-25" },
  { id: "5", cliente: "Telecom del Sur S.A.", serie: "PW90-7781-ZZ", equipo: "Genérico Fuente 12V 2A", venceEl: "2026-10-04" },
]);

/**
 * KPIs. Se CALCULAN sobre las órdenes de arriba en vez de escribirse a mano:
 * un tablero de demostración que dice "12 abiertas" encima de una tabla con 7
 * se revisa mal, porque quien lo mira deja de creerse los dos números. En la
 * pantalla real cada uno será un agregado de Postgres (`count(*) ... where`),
 * y la definición que hay aquí es justamente la del `where` que hará falta.
 *
 * `tendencia` es 'positiva' | 'negativa' | null, nunca un color: el color lo
 * decide la hoja de estilos.
 */
const abiertas = ORDENES.filter((o) => !ESTADOS_TERMINALES.includes(o.estado));
const sinTecnico = abiertas.filter((o) => !o.tecnico).length;

export const KPIS = Object.freeze([
  {
    clave: "abiertas",
    etiqueta: "Órdenes abiertas",
    valor: abiertas.length,
    nota: sinTecnico === 1 ? "1 sin técnico asignado" : `${sinTecnico} sin técnico asignado`,
    tendencia: sinTecnico > 0 ? "negativa" : null,
  },
  {
    clave: "diagnostico",
    etiqueta: "En diagnóstico",
    valor: ORDENES.filter((o) => o.estado === "EN_DIAGNOSTICO").length,
    nota: "el diagnóstico no debe pasar de 48 h",
    tendencia: null,
  },
  {
    clave: "porVencer",
    etiqueta: "Garantías por vencer",
    valor: POR_VENCER.length,
    nota: "en los próximos 30 días",
    tendencia: null,
  },
  {
    clave: "reparadas",
    etiqueta: "Listas para entregar",
    valor: ORDENES.filter((o) => o.estado === "REPARADO").length,
    nota: "reparadas, esperando al cliente",
    tendencia: "positiva",
  },
]);
