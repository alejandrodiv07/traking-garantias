/**
 * Datos de DEMOSTRACIÓN para la consulta interna de garantías.
 *
 * =============================================================================
 * NO ES UNA FUENTE DE DATOS REAL. Todavía no existe una RPC para esta
 * pantalla: `consultar_garantia()` (migración 20260906000002) es la función
 * PÚBLICA del portal del cliente -- exige nº de orden + token, y solo
 * devuelve lo mínimo (§4 Fase 4 de `docs/2026-09-09-estado-del-proyecto.md`).
 * El mostrador necesita lo contrario: buscar por CUALQUIERA de cuatro
 * campos (serial, cédula/RIF, factura, orden) sin conocer un token, y ver
 * el detalle completo -- cliente, documentos, historial de órdenes -- que
 * el portal público nunca expone. Eso es una RPC nueva
 * (`consultar_garantia_interna`, con su propia RLS) que cuelga de la
 * "Ficha de detalle de la orden" ya listada como pendiente en ese documento.
 *
 * Mientras tanto, este fichero deja la pantalla usable de verdad -- se
 * puede buscar, ver resultados y ver el estado "sin resultado" -- sin
 * fingir que la base de datos ya responde. `datos/consultaGarantia.js` es
 * el único sitio que conoce esta lista; el día que exista la RPC, ese
 * fichero cambia de cuerpo y ninguna otra pieza de la pantalla se entera.
 * =============================================================================
 */

export const GARANTIAS_DEMO = [
  {
    id: "demo-1",
    equipo: {
      nombre: "Router Industrial EA2-RT500",
      marca: "EA2 Technology",
      categoria: "Conectividad industrial",
      serial: "RT5-8842-AA",
      numeroFactura: "V-0012",
      fechaCompra: "2026-01-10",
      finCobertura: "2027-01-10",
      cobertura: "EN_GARANTIA",
    },
    cliente: {
      nombre: "Comercializadora Andina",
      documento: "J-30589214-7",
      contacto: "Luisa Fernández",
      email: "compras@andina.com.ve",
      telefono: "+58 212 555 0142",
    },
    documentos: [
      {
        id: "doc-1",
        tipo: "FACTURA",
        nombreArchivo: "factura-V-0012.pdf",
        etiqueta: "Factura escaneada",
        rutaStorage: "demo-1/factura-v-0012.pdf",
      },
      {
        id: "doc-2",
        tipo: "OTRO",
        nombreArchivo: "orden-OS-0142.pdf",
        etiqueta: "Orden de servicio",
        rutaStorage: "demo-1/orden-os-0142.pdf",
      },
    ],
    ordenes: [
      {
        numero: "OS-2026-0142",
        falla: "No enciende tras corte eléctrico",
        estado: "EN_DIAGNOSTICO",
        fecha: "2026-09-02",
      },
      {
        numero: "OS-2026-0031",
        falla: "Actualización de firmware",
        estado: "ENTREGADO",
        fecha: "2026-03-14",
      },
    ],
  },
  {
    id: "demo-2",
    equipo: {
      nombre: "Cámara PTZ Dominus 4K",
      marca: "Dominus Vision",
      categoria: "Videovigilancia",
      serial: "DV4-1207-BE",
      numeroFactura: "V-0087",
      fechaCompra: "2025-04-22",
      finCobertura: "2026-04-22",
      cobertura: "EN_GARANTIA",
    },
    cliente: {
      nombre: "Ferretería Los Robles, C.A.",
      documento: "J-29887410-2",
      contacto: "Miguel Ontiveros",
      email: "compras@losrobles.com.ve",
      telefono: "+58 241 555 8820",
    },
    documentos: [
      {
        id: "doc-3",
        tipo: "FACTURA",
        nombreArchivo: "factura-V-0087.pdf",
        etiqueta: "Factura escaneada",
        rutaStorage: "demo-2/factura-v-0087.pdf",
      },
    ],
    ordenes: [
      {
        numero: "OS-2025-0304",
        falla: "Imagen con interferencia nocturna",
        estado: "REPARADO",
        fecha: "2025-11-18",
      },
    ],
  },
  {
    id: "demo-3",
    equipo: {
      nombre: "UPS Trifásico Vantia 10kVA",
      marca: "Vantia Power",
      categoria: "Respaldo eléctrico",
      serial: "VP10-5563-CC",
      numeroFactura: "V-0004",
      fechaCompra: "2024-06-01",
      finCobertura: "2025-06-01",
      cobertura: "FUERA_DE_GARANTIA",
    },
    cliente: {
      nombre: "Corporación Industrial Zuliana",
      documento: "J-31220987-5",
      contacto: "Ana Belisario",
      email: "mantenimiento@zuliana.ind.ve",
      telefono: "+58 261 555 1190",
    },
    documentos: [
      {
        id: "doc-4",
        tipo: "FACTURA",
        nombreArchivo: "factura-V-0004.pdf",
        etiqueta: "Factura escaneada",
        rutaStorage: "demo-3/factura-v-0004.pdf",
      },
    ],
    ordenes: [
      {
        numero: "OS-2024-0091",
        falla: "Cambio de baterías programado",
        estado: "ENTREGADO",
        fecha: "2024-11-02",
      },
    ],
  },
];
