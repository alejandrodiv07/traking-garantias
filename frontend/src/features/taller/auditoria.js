// Puntos de la auditoría de recepción y su checklist (sin componentes: ver AuditoriaRecepcion.jsx).
export const PUNTOS = [
  {
    clave: "condiciones",
    titulo: "Condiciones del trámite",
    items: [
      ["factura_presentada", "La factura o nota está sin alteraciones"],
      ["titular_coincide", "Quien tramita coincide con el titular de la factura"],
    ],
  },
  {
    clave: "equipo",
    titulo: "Estado del equipo",
    items: [
      ["serial_legible", "El serial de fábrica es legible"],
      ["caja_original", "Trae la caja original"],
      ["precintos_intactos", "Los precintos de seguridad están intactos"],
      ["contenido_completo", "El equipo no fue abierto y está todo su contenido"],
    ],
  },
];
export const SENALES = [
  ["descarga_electrica", "Descarga eléctrica"],
  ["liquidos", "Derrame de líquidos"],
  ["altas_temperaturas", "Altas temperaturas"],
  ["golpes", "Golpes"],
  ["manipulacion_terceros", "Manipulación de terceros"],
];

/** ¿Están los seis puntos respondidos? (las señales son opcionales) */
export function auditoriaCompleta(checklist) {
  return PUNTOS.every((g) => g.items.every(([k]) => typeof checklist?.[g.clave]?.[k] === "boolean"));
}

/** El checklist que viaja a la base: todas las casillas con booleanos (señal sin marcar = false). */
export function checklistParaBase(checklist) {
  const c = {};
  for (const g of PUNTOS) {
    c[g.clave] = {};
    for (const [k] of g.items) c[g.clave][k] = Boolean(checklist?.[g.clave]?.[k]);
  }
  c.senales = {};
  for (const [k] of SENALES) c.senales[k] = Boolean(checklist?.senales?.[k]);
  return c;
}
