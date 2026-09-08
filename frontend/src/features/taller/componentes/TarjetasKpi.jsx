/**
 * Las cuatro tarjetas de KPI. Antes vivían incrustadas en `Tablero.jsx`
 * sobre `datosDemo.KPIS`; ahora reciben el resultado crudo de
 * `kpis_tablero()` y hacen la traducción a las cuatro tarjetas del mockup
 * aquí (tabla de correspondencia, §3.2 del spec).
 *
 * Estados de la zona (§6.2): "cargando" es un esqueleto, nunca un `0` --
 * un taller vacío de verdad también muestra `0`, y confundir ambos casos es
 * el error de diseño que el spec marca como el más probable de esta
 * pantalla. "Error" es un guion con aviso discreto, no una tarjeta rota.
 */
export default function TarjetasKpi({ kpis, cargando, error }) {
  if (error) {
    return (
      <ul className="tg-kpis" aria-label="Indicadores del taller">
        <li className="tg-card tg-kpi tg-kpi--error" role="status">
          <p className="tg-kpi-etiqueta">Indicadores</p>
          <p className="tg-kpi-valor">—</p>
          <p className="tg-kpi-nota">No se pudieron cargar los indicadores.</p>
        </li>
      </ul>
    );
  }

  if (cargando || !kpis) {
    return (
      <ul className="tg-kpis" aria-label="Indicadores del taller, cargando">
        {[0, 1, 2, 3].map((i) => (
          <li className="tg-card tg-kpi tg-kpi--esqueleto" key={i} aria-hidden="true">
            <span className="tg-kpi-esqueleto-linea" />
            <span className="tg-kpi-esqueleto-linea tg-kpi-esqueleto-linea--valor" />
            <span className="tg-kpi-esqueleto-linea" />
          </li>
        ))}
      </ul>
    );
  }

  const nuevasSemana = kpis.nuevas_semana ?? 0;
  const tasa = kpis.tasa_a_tiempo != null ? Math.round(Number(kpis.tasa_a_tiempo)) : null;

  const tarjetas = [
    {
      clave: "abiertas",
      etiqueta: "Órdenes abiertas",
      valor: kpis.ordenes_abiertas ?? 0,
      nota: nuevasSemana > 0 ? `▲ ${nuevasSemana} esta semana` : "sin nuevas esta semana",
      tendencia: nuevasSemana > 0 ? "positiva" : null,
    },
    {
      clave: "diagnostico",
      etiqueta: "En diagnóstico",
      valor: kpis.en_diagnostico ?? 0,
      // El rótulo del mockup decía "2 con SLA por vencer" como si fuera solo
      // de diagnóstico; `sla_por_vencer` cuenta TODAS las órdenes abiertas
      // (§3.2), así que el texto se corrige para no prometer un recorte que
      // el dato no hace.
      nota: `${kpis.sla_por_vencer ?? 0} con SLA por vencer en el taller`,
      tendencia: (kpis.sla_por_vencer ?? 0) > 0 ? "negativa" : null,
    },
    {
      clave: "porVencer",
      etiqueta: "Garantías por vencer",
      valor: kpis.por_vencer_30d ?? 0,
      nota: "próximos 30 días",
      tendencia: null,
    },
    {
      clave: "reparadas",
      etiqueta: "Reparadas (mes)",
      valor: kpis.reparadas_mes ?? 0,
      nota: tasa != null ? `tasa ${tasa}% a tiempo` : "sin entregas este mes",
      tendencia: tasa != null && tasa >= 90 ? "positiva" : null,
    },
  ];

  return (
    <ul className="tg-kpis" aria-label="Indicadores del taller">
      {tarjetas.map((k) => (
        <li className="tg-card tg-kpi" key={k.clave}>
          <p className="tg-kpi-etiqueta">{k.etiqueta}</p>
          <p className="tg-kpi-valor">{k.valor}</p>
          <p className="tg-kpi-nota" data-tendencia={k.tendencia ?? undefined}>
            {k.nota}
          </p>
        </li>
      ))}
    </ul>
  );
}
