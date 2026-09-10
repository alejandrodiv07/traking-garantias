/**
 * Búsqueda de una garantía por criterio libre (serial, cédula/RIF, nº de
 * factura o nº de orden) para el personal de mostrador.
 *
 * TODO(Fase 2.1/Fase 4, ver `docs/2026-09-09-estado-del-proyecto.md` §3):
 * falta la RPC `consultar_garantia_interna(criterio)`. `consultar_garantia()`
 * (migración 20260906000002) es la del PORTAL PÚBLICO -- exige token, y no
 * sirve aquí. Mientras esa función no exista, esta busca en `GARANTIAS_DEMO`
 * para que la pantalla sea real de usar; cuando la RPC exista, solo cambia
 * el cuerpo de esta función -- `ConsultaGarantia.jsx` no se entera.
 */
import { GARANTIAS_DEMO } from "./garantiasDemo.js";

function normalizar(valor) {
  return String(valor ?? "").trim().toLowerCase();
}

/** Coincide si el criterio es exactamente el campo, o un fragmento de él.
    Un serial completo debe encontrar la orden aunque el usuario también
    pueda escribir solo un pedazo (§ búsqueda del tablero, mismo criterio). */
function coincide(campo, criterio) {
  const valor = normalizar(campo);
  return valor.length > 0 && valor.includes(criterio);
}

/**
 * Devuelve la garantía que coincide con el criterio, `undefined` si ninguna
 * coincide, o `null` si el criterio viene vacío (nada que buscar todavía).
 * Simula latencia de red para que el estado "Buscando…" sea comprobable.
 */
export async function buscarGarantia(criterioCrudo) {
  const criterio = normalizar(criterioCrudo);
  await new Promise((resolver) => setTimeout(resolver, 380));

  if (criterio.length === 0) return null;

  return GARANTIAS_DEMO.find(
    (g) =>
      coincide(g.equipo.serial, criterio) ||
      coincide(g.cliente.documento, criterio) ||
      coincide(g.equipo.numeroFactura, criterio) ||
      g.ordenes.some((o) => coincide(o.numero, criterio))
  );
}
