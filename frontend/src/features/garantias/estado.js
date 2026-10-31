// Estado de una garantía para mostrar (tablero y ficha): sale de lo que ya
// calcula la base (vigencia, días restantes, estado de la compra).
export const POR_VENCER_DIAS = 3;

export const ESTADOS = {
  vigente: { n: "Vigente", t: "ok", ficha: "Garantía vigente" },
  porvencer: { n: "Por vencer", t: "ambar", ficha: "Garantía vigente" },
  vencida: { n: "Vencida", t: "mal", ficha: "Garantía vencida" },
  confirmar: { n: "Por confirmar", t: "neutro", ficha: "Por confirmar" },
  desestimada: { n: "Compra desestimada", t: "mal", ficha: "Compra desestimada" },
};

export function estadoDe(g) {
  if (g.estado_compra === "DESESTIMADA") return "desestimada";
  if (g.estado_compra === "PENDIENTE") return "confirmar";
  if (g.vigencia === "FUERA_DE_GARANTIA") return "vencida";
  if (g.dias_restantes <= POR_VENCER_DIAS) return "porvencer";
  return "vigente";
}
