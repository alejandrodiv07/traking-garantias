/**
 * Lista de órdenes del Taller (maqueta 04, /taller): indicadores, búsqueda,
 * chips por estado con conteo y una fila por orden que abre su detalle. Lee la
 * misma vista que el Tablero (`v_tablero`, ya ordenada por urgencia); la
 * búsqueda y los chips se aplican en el navegador sobre lo cargado (200 filas).
 */
import { useEffect, useState } from "react";
import { Link, useNavigate, useSearchParams } from "react-router-dom";
import { Plus, Search, Wrench, X } from "lucide-react";
import { cobertura, estado as estadoDe, FILTROS } from "../tablero/dominio.js";
import { listarTablero } from "../tablero/tableroService.js";

const CHIPS = [...FILTROS, { clave: "RECHAZADO", etiqueta: "Rechazado", estados: ["RECHAZADO"] }];
const TONO = { neutro: "neutro", progreso: "ambar", resuelto: "ok", adverso: "mal" };
const MES = ["ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sep", "oct", "nov", "dic"];

const norm = (s) => String(s ?? "").toUpperCase().replace(/[\s-]/g, "");
const atencion = (c) => (c === "EN_GARANTIA" ? "Garantía" : c === "POR_DETERMINAR" ? "Por determinar" : "Servicio pago");

function fcorta(iso) {
  const [, m, d] = String(iso).slice(0, 10).split("-");
  return `${Number(d)} ${MES[Number(m) - 1]}`;
}

export default function Taller() {
  const navigate = useNavigate();
  const [params] = useSearchParams();
  const [filas, setFilas] = useState(null);
  const [error, setError] = useState(null);
  const [chip, setChip] = useState("TODAS");
  const [q, setQ] = useState(params.get("buscar") ?? "");

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

  const todas = filas ?? [];
  const buscado = norm(q);
  const base = todas.filter((f) => !buscado || norm(f.numero_orden + f.cliente + f.serial + f.documento + f.numero_soporte).includes(buscado));
  const cuenta = (c) => base.filter((f) => !c.estados || c.estados.includes(f.estado)).length;
  const estados = CHIPS.find((c) => c.clave === chip).estados;
  const visibles = base.filter((f) => !estados || estados.includes(f.estado));
  const kpi = (...e) => todas.filter((f) => e.includes(f.estado)).length;

  return (
    <>
      <div className="enc">
        <div>
          <h1>Taller</h1>
          {filas && <p className="sub">{todas.filter((f) => f.abierto).length} órdenes abiertas · {todas.length} en total</p>}
        </div>
        <button type="button" className="btn principal" onClick={() => navigate("/garantias/consulta")}>
          <Plus size={17} strokeWidth={2.4} aria-hidden="true" />
          Nueva orden
        </button>
      </div>

      <ul className="kpis">
        <li className="card kpi">
          <h2>Abiertas</h2>
          <p className="v">{todas.filter((f) => f.abierto).length}</p>
          <p className="n">en el taller ahora</p>
        </li>
        <li className="card kpi ambar">
          <h2>En diagnóstico</h2>
          <p className="v">{kpi("EN_DIAGNOSTICO", "PRESUPUESTADO")}</p>
          <p className="n">por revisar o presupuestar</p>
        </li>
        <li className="card kpi ambar">
          <h2>En reparación</h2>
          <p className="v">{kpi("EN_REPARACION", "EN_ESPERA_REPUESTO")}</p>
          <p className="n">en el banco de trabajo</p>
        </li>
        <li className="card kpi ok">
          <h2>Listas</h2>
          <p className="v">{kpi("REPARADO")}</p>
          <p className="n">para entregar al cliente</p>
        </li>
      </ul>

      <section aria-label="Órdenes del taller">
        <div className="filtros tl-filtros">
          <div className="buscar">
            <label className="sr" htmlFor="tl-q">
              Buscar por orden, cliente, serial o factura
            </label>
            <Search className="lupa" size={18} aria-hidden="true" />
            <input
              id="tl-q"
              className="campo"
              type="search"
              autoComplete="off"
              placeholder="Buscar por n.º de orden, cliente, serial o factura…"
              value={q}
              onChange={(e) => setQ(e.target.value)}
            />
            {q && (
              <button type="button" className="limpiar" aria-label="Borrar la búsqueda" onClick={() => setQ("")}>
                <X size={16} strokeWidth={2} aria-hidden="true" />
              </button>
            )}
          </div>
        </div>

        <div className="chips" role="group" aria-label="Filtrar por estado">
          {CHIPS.map((c) => (
            <button key={c.clave} type="button" className="chip" aria-pressed={c.clave === chip} onClick={() => setChip(c.clave)}>
              {c.etiqueta} <span className="q">{cuenta(c)}</span>
            </button>
          ))}
        </div>
        <p className="sr" role="status" aria-live="polite">
          {filas ? `${visibles.length} órdenes visibles` : ""}
        </p>

        {error && (
          <p role="alert" className="aviso-error">
            {error}
          </p>
        )}

        <div className="card caja fichas">
          {visibles.length > 0 && (
            <div className="scroll">
              <table>
                <caption className="sr">Órdenes del taller por urgencia</caption>
                <thead>
                  <tr>
                    <th scope="col">Orden</th>
                    <th scope="col">Cliente</th>
                    <th scope="col">Equipo</th>
                    <th scope="col">Atención</th>
                    <th scope="col">Estado</th>
                    <th scope="col">Ingresó</th>
                    <th scope="col">
                      <span className="sr">Acción</span>
                    </th>
                  </tr>
                </thead>
                <tbody>
                  {visibles.map((f) => {
                    const e = estadoDe(f.estado);
                    return (
                      <tr key={f.orden_id}>
                        <td data-l="Orden">
                          <Link to={`/taller/${f.orden_id}`} className="serie mono">
                            {f.numero_orden}
                          </Link>
                        </td>
                        <td data-l="Cliente">
                          <div>
                            <div className="p">{f.cliente}</div>
                            <div className="s mono">{f.documento}</div>
                          </div>
                        </td>
                        <td data-l="Equipo">
                          <div>
                            <div className="p">{f.producto}</div>
                            <div className="s mono">{f.serial}</div>
                          </div>
                        </td>
                        <td data-l="Atención">
                          <span className="ins" data-t={TONO[cobertura(f.cobertura).tono] ?? "neutro"}>
                            <i />
                            {atencion(f.cobertura)}
                          </span>
                        </td>
                        <td data-l="Estado">
                          <span className="ins" data-t={TONO[e.tono] ?? "neutro"}>
                            <i />
                            {f.estado_nombre}
                          </span>
                        </td>
                        <td data-l="Ingresó">
                          <div className="dias">
                            {fcorta(f.fecha_ingreso)}
                            {f.abierto && typeof f.dias_en_taller === "number" && <div className="s">{f.dias_en_taller} d en taller</div>}
                          </div>
                        </td>
                        <td data-l="">
                          <button type="button" className="abrir" onClick={() => navigate(`/taller/${f.orden_id}`)}>
                            Ver<span className="sr"> orden {f.numero_orden}</span>
                          </button>
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          )}
          {filas && visibles.length === 0 && (
            <div className="vacio">
              <Wrench size={34} strokeWidth={1.6} aria-hidden="true" />
              <h3>No hay órdenes para este filtro</h3>
              <p>Cambia el estado, quita la búsqueda o abre una orden desde la Consulta de garantía.</p>
              <button type="button" className="btn principal" onClick={() => navigate("/garantias/consulta")}>
                Nueva orden
              </button>
            </div>
          )}
          <div className="tpie">
            <span>{filas ? `Mostrando ${visibles.length} de ${todas.length} órdenes` : "Cargando…"}</span>
          </div>
        </div>
      </section>
    </>
  );
}
