/**
 * Tablero de garantías (maqueta 01, /garantias): una fila por equipo registrado.
 * Los chips clasifican con lo que ya calcula la base (vigencia, días restantes,
 * estado de la compra); la búsqueda se hace en la base.
 */
import { useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import { listarGarantias } from "./garantiasService.js";
import "./garantias.css";

const POR_VENCER_DIAS = 3;

const CHIPS = [
  ["Todas", () => true],
  ["Vigente", (g) => g.vigencia === "EN_GARANTIA"],
  ["Por vencer", (g) => g.vigencia === "EN_GARANTIA" && g.dias_restantes <= POR_VENCER_DIAS],
  ["Vencida", (g) => g.vigencia === "FUERA_DE_GARANTIA"],
  ["Por confirmar", (g) => g.estado_compra === "PENDIENTE"],
];

function estadoDe(g) {
  if (g.estado_compra === "PENDIENTE") return "Por confirmar";
  if (g.estado_compra === "DESESTIMADA") return "Compra desestimada";
  if (g.vigencia === "FUERA_DE_GARANTIA") return "Vencida";
  if (g.dias_restantes <= POR_VENCER_DIAS) return "Por vencer";
  return "Vigente";
}

export default function Garantias() {
  const navigate = useNavigate();
  const [busqueda, setBusqueda] = useState("");
  const [chip, setChip] = useState("Todas");
  const [filas, setFilas] = useState(null);
  const [error, setError] = useState(null);

  // La búsqueda va a la base con una pausa, como el Tablero.
  useEffect(() => {
    let vivo = true;
    const t = setTimeout(() => {
      listarGarantias({ busqueda }).then((r) => {
        if (!vivo) return;
        setError(r.ok ? null : r.mensaje || "No se pudo cargar");
        if (r.ok) setFilas(r.datos);
      });
    }, busqueda ? 250 : 0);
    return () => {
      vivo = false;
      clearTimeout(t);
    };
  }, [busqueda]);

  const filtro = CHIPS.find(([n]) => n === chip)[1];
  const visibles = (filas ?? []).filter(filtro);

  return (
    <section className="gr">
      <header className="gr-cab">
        <h1>Garantías</h1>
        <button type="button" className="ng-principal" onClick={() => navigate("/garantias/nueva")}>
          Nueva garantía
        </button>
      </header>

      <label htmlFor="gr-buscar">
        Buscar
        <input
          id="gr-buscar"
          value={busqueda}
          onChange={(e) => setBusqueda(e.target.value)}
          placeholder="Serial, titular, cédula o factura"
          autoComplete="off"
        />
      </label>

      <div className="gr-chips" role="group" aria-label="Filtrar por estado">
        {CHIPS.map(([nombre]) => (
          <button key={nombre} type="button" aria-pressed={nombre === chip} onClick={() => setChip(nombre)}>
            {nombre}
          </button>
        ))}
      </div>

      {error && <p role="alert">{error}</p>}
      {filas && visibles.length === 0 && <p role="status">No hay garantías para este filtro.</p>}

      {visibles.length > 0 && (
        <table className="gr-tabla">
          <caption className="gr-sr">Garantías registradas</caption>
          <thead>
            <tr>
              <th scope="col">Serial</th>
              <th scope="col">Titular</th>
              <th scope="col">Equipo</th>
              <th scope="col">Factura</th>
              <th scope="col">Emisión</th>
              <th scope="col">Vence</th>
              <th scope="col">Estado</th>
            </tr>
          </thead>
          <tbody>
            {visibles.map((g) => (
              <tr
                key={g.equipo_id}
                onClick={() => navigate(`/garantias/consulta?serial=${encodeURIComponent(g.numero_serie)}`)}
              >
                <td className="cs-serial">{g.numero_serie}</td>
                <td>{g.titular}</td>
                <td>{g.producto}</td>
                <td>{g.numero_soporte ?? "—"}</td>
                <td>{g.fecha_emision ?? "—"}</td>
                <td>{g.vence_el ?? "—"}</td>
                <td>{estadoDe(g)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </section>
  );
}
