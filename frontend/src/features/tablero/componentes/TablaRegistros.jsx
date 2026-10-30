// Tabla de registros del Tablero (Tarea 20 del plan; spec §7.3).
// Los dos tiempos por separado, cada uno con su color: los días que le
// quedan a la GARANTÍA y los que lleva el equipo EN EL TALLER (SLA). Una
// fila sin fecha de vencimiento dice "Sin factura", no un guion.
const TONO = {
  VENCIDA: "tg-nivel--rojo",
  HOY: "tg-nivel--rojo",
  CRITICA: "tg-nivel--naranja",
  CRITICO: "tg-nivel--naranja",
  PRONTO: "tg-nivel--amarillo",
  ALERTA: "tg-nivel--amarillo",
  NORMAL: "tg-nivel--verde",
  PENDIENTE: "tg-nivel--gris",
};
const tono = (nivel) => TONO[nivel] ?? "tg-nivel--gris";

export default function TablaRegistros({ filas, rol, onRevisar }) {
  if (filas.length === 0) {
    return (
      <p className="tg-vacio" role="status">
        Sin registros. Cuando reciban un equipo por garantía, aparece aquí.
      </p>
    );
  }

  return (
    <div className="tg-scroll">
      <table className="tg-tabla">
        <caption className="tg-sr">Registros del taller por urgencia</caption>
        <thead>
          <tr>
            <th scope="col">Código</th>
            <th scope="col">Equipo</th>
            <th scope="col">Titular</th>
            <th scope="col">Estado</th>
            <th scope="col">Cobertura</th>
            <th scope="col">Garantía</th>
            <th scope="col">En taller</th>
            {rol !== "RECEPCION" && <th scope="col">Revisar</th>}
          </tr>
        </thead>
        <tbody>
          {filas.map((f) => (
            <tr key={f.orden_id}>
              <td>{f.numero_orden}</td>
              <td>
                {f.producto}
                <span className="tg-tabla-serial">{f.serial}</span>
              </td>
              <td>
                {f.cliente}
                <span className="tg-tabla-serial">{f.documento}</span>
              </td>
              <td>{f.estado_nombre}</td>
              <td>{f.cobertura}</td>
              <td className={tono(f.nivel_vigencia)}>
                {f.nivel_vigencia === "PENDIENTE"
                  ? "Sin factura"
                  : `${f.dias_restantes} d`}
              </td>
              <td className={tono(f.nivel_sla)}>{f.dias_en_taller} días en taller</td>
              {rol !== "RECEPCION" && (
                <td>
                  {f.abierto && (
                    <button type="button" aria-label={`Revisar ${f.numero_orden}`} onClick={() => onRevisar?.(f)}>
                      Revisar
                    </button>
                  )}
                </td>
              )}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}