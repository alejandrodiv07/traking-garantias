/**
 * Lista de órdenes del Taller (spec §8, Tarea 17): chips por estado y una fila
 * por orden que abre su detalle. Lee la misma vista que el Tablero (`v_tablero`,
 * ya ordenada por urgencia); el filtro por chip se aplica sobre lo cargado.
 */
import { useEffect, useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import { cobertura, FILTROS } from "../tablero/dominio.js";
import { listarTablero } from "../tablero/tableroService.js";
import "./taller.css";

const CHIPS = [...FILTROS, { clave: "RECHAZADO", etiqueta: "Rechazado", estados: ["RECHAZADO"] }];

export default function Taller() {
  const navigate = useNavigate();
  const [filas, setFilas] = useState(null);
  const [error, setError] = useState(null);
  const [chip, setChip] = useState("TODAS");

  useEffect(() => {
    let vivo = true;
    listarTablero().then((r) => {
      if (!vivo) return;
      if (r.ok) setFilas(r.filas);
      else setError(r.mensaje || "No se pudo cargar el taller");
    });
    return () => {
      vivo = false;
    };
  }, []);

  const estados = CHIPS.find((c) => c.clave === chip).estados;
  const visibles = (filas ?? []).filter((f) => !estados || estados.includes(f.estado));

  return (
    <section className="tl">
      <header className="tl-cab">
        <h1>Taller</h1>
        <button type="button" className="ao-principal" onClick={() => navigate("/garantias/consulta")}>
          Nueva orden
        </button>
      </header>

      <div className="tl-chips" role="group" aria-label="Filtrar por estado">
        {CHIPS.map((c) => (
          <button
            key={c.clave}
            type="button"
            className="tl-chip"
            aria-pressed={c.clave === chip}
            onClick={() => setChip(c.clave)}
          >
            {c.etiqueta}
          </button>
        ))}
      </div>

      {error && <p role="alert">{error}</p>}
      {filas && visibles.length === 0 && <p role="status">No hay órdenes para este filtro.</p>}

      {visibles.length > 0 && (
        <table className="tl-tabla">
          <caption className="tl-sr">Órdenes del taller por urgencia</caption>
          <thead>
            <tr>
              <th scope="col">Orden</th>
              <th scope="col">Cliente</th>
              <th scope="col">Equipo</th>
              <th scope="col">Garantía</th>
              <th scope="col">Estado</th>
              <th scope="col">Ingresó</th>
            </tr>
          </thead>
          <tbody>
            {visibles.map((f) => (
              <tr key={f.orden_id} onClick={() => navigate(`/taller/${f.orden_id}`)}>
                <td>
                  <Link to={`/taller/${f.orden_id}`} onClick={(e) => e.stopPropagation()}>
                    {f.numero_orden}
                  </Link>
                </td>
                <td>{f.cliente}</td>
                <td>{f.producto}</td>
                <td>{cobertura(f.cobertura).nombre}</td>
                <td>{f.estado_nombre}</td>
                <td>{String(f.fecha_ingreso).slice(0, 10)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </section>
  );
}
