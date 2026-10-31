/**
 * Tablero de garantías (maqueta 01, /garantias): una fila por equipo
 * registrado. Los estados salen de lo que ya calcula la base (vigencia, días
 * restantes, estado de la compra); el filtrado es en el navegador sobre las
 * garantías que vencen primero (límite de 200 de `listarGarantias`).
 */
import { useEffect, useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import { ArrowDown, ArrowUp, Plus, Search, ShieldCheck, X } from "lucide-react";
import { useAuth } from "../auth/AuthContext.jsx";
import { listarGarantias } from "./garantiasService.js";
import { ESTADOS, estadoDe } from "./estado.js";
import InsigniaVerificacion from "./InsigniaVerificacion.jsx";

const ROLES_JEFATURA = ["ADMIN", "JEFE_SERVICIO"];
const LIMITE = 200;

const CHIPS = [
  ["todas", "Todas"],
  ["vigente", "Vigentes"],
  ["porvencer", "Por vencer"],
  ["vencida", "Vencidas"],
  ["confirmar", "Por confirmar"],
];
const MES = ["ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sep", "oct", "nov", "dic"];

// Las fechas llegan como AAAA-MM-DD: se cortan a mano para no mover el día por zona horaria.
function fcorta(iso) {
  if (!iso) return "—";
  const [, m, d] = iso.split("-");
  return `${Number(d)} ${MES[Number(m) - 1]}`;
}

const norm = (s) => String(s ?? "").toUpperCase().replace(/[\s-]/g, "");

function textoDias(g, estado) {
  if (estado === "confirmar") return <span className="s">Pendiente de confirmar</span>;
  if (typeof g.dias_restantes !== "number") return null;
  if (g.dias_restantes < 0) return <strong>Venció hace {Math.abs(g.dias_restantes)} d</strong>;
  if (g.dias_restantes === 0) return <strong>Vence hoy</strong>;
  return <strong>{g.dias_restantes === 1 ? "1 día" : `${g.dias_restantes} días`}</strong>;
}

export default function Garantias() {
  const navigate = useNavigate();
  const { rol } = useAuth();
  const [q, setQ] = useState("");
  const [chip, setChip] = useState("todas");
  const [desde, setDesde] = useState("");
  const [hasta, setHasta] = useState("");
  const [asc, setAsc] = useState(true);
  const [filas, setFilas] = useState(null);
  const [error, setError] = useState(null);

  useEffect(() => {
    let vivo = true;
    listarGarantias().then((r) => {
      if (!vivo) return;
      if (r.ok) setFilas(r.datos);
      else setError(r.mensaje || "No se pudo cargar");
    });
    return () => {
      vivo = false;
    };
  }, []);

  const todas = (filas ?? []).map((g) => ({ g, e: estadoDe(g) }));
  const buscado = norm(q);
  const base = todas.filter(({ g }) => {
    if (buscado && !norm(g.numero_serie + g.documento + g.numero_soporte + g.titular).includes(buscado)) return false;
    if (desde && (g.fecha_emision ?? "") < desde) return false;
    if (hasta && (g.fecha_emision ?? "9999") > hasta) return false;
    return true;
  });
  const cuenta = { todas: base.length, vigente: 0, porvencer: 0, vencida: 0, confirmar: 0 };
  base.forEach(({ e }) => {
    if (e in cuenta) cuenta[e] += 1;
  });
  const global = { vigente: 0, porvencer: 0, vencida: 0, confirmar: 0 };
  todas.forEach(({ e }) => {
    if (e in global) global[e] += 1;
  });
  const visibles = base
    .filter(({ e }) => chip === "todas" || e === chip)
    .sort((a, b) => {
      const va = a.g.vence_el ?? "9999";
      const vb = b.g.vence_el ?? "9999";
      return asc ? va.localeCompare(vb) : vb.localeCompare(va);
    });

  return (
    <>
      <div className="enc">
        <div>
          <h1>Tablero de garantías</h1>
          {filas && (
            <p className="sub">
              {filas.length} garantías registradas · {base.length} con los filtros actuales
            </p>
          )}
        </div>
        <div className="enc-acc">
          {ROLES_JEFATURA.includes(rol) && (
            <Link to="/ventas/importar" className="btn suave">
              Importar ventas
            </Link>
          )}
          <button type="button" className="btn principal" onClick={() => navigate("/garantias/nueva")}>
            <Plus size={17} strokeWidth={2.4} aria-hidden="true" />
            Nueva garantía
          </button>
        </div>
      </div>

      <ul className="kpis">
        <li className="card kpi">
          <h2>Registradas</h2>
          <p className="v">{todas.length}</p>
          <p className="n">{global.confirmar} por confirmar</p>
        </li>
        <li className="card kpi ok">
          <h2>Vigentes</h2>
          <p className="v">{global.vigente}</p>
          <p className="n">cobertura activa hoy</p>
        </li>
        <li className="card kpi ambar">
          <h2>Vencen en 3 días</h2>
          <p className="v">{global.porvencer}</p>
          <p className="n">avisar al titular</p>
        </li>
        <li className="card kpi mal">
          <h2>Vencidas</h2>
          <p className="v">{global.vencida}</p>
          <p className="n">se atienden como servicio pago</p>
        </li>
      </ul>

      <section aria-label="Garantías registradas">
        <div className="filtros">
          <div className="buscar">
            <label className="sr" htmlFor="gr-q">
              Buscar por serial, cédula o RIF, o número de factura
            </label>
            <Search className="lupa" size={18} aria-hidden="true" />
            <input
              id="gr-q"
              className="campo"
              type="search"
              autoComplete="off"
              placeholder="Buscar por serial, cédula/RIF o n.º de factura…"
              value={q}
              onChange={(e) => setQ(e.target.value)}
            />
            {q && (
              <button type="button" className="limpiar" aria-label="Borrar la búsqueda" onClick={() => setQ("")}>
                <X size={16} strokeWidth={2} aria-hidden="true" />
              </button>
            )}
          </div>
          <div className="fecha">
            <label htmlFor="gr-desde">Emitida desde</label>
            <input id="gr-desde" className="campo" type="date" value={desde} onChange={(e) => setDesde(e.target.value)} />
          </div>
          <div className="fecha">
            <label htmlFor="gr-hasta">Hasta</label>
            <input id="gr-hasta" className="campo" type="date" value={hasta} onChange={(e) => setHasta(e.target.value)} />
          </div>
          {(desde || hasta) && (
            <button
              type="button"
              className="btn suave btn-lim"
              onClick={() => {
                setDesde("");
                setHasta("");
              }}
            >
              Quitar fechas
            </button>
          )}
        </div>

        <div className="chips" role="group" aria-label="Filtrar por estado">
          {CHIPS.map(([k, nombre]) => (
            <button key={k} type="button" className="chip" aria-pressed={chip === k} onClick={() => setChip(k)}>
              {nombre} <span className="q">{cuenta[k]}</span>
            </button>
          ))}
        </div>
        <p className="sr" role="status" aria-live="polite">
          {filas ? `${visibles.length} garantías visibles` : ""}
        </p>

        {error && (
          <p role="alert" className="aviso-error">
            {error}
          </p>
        )}

        <div className="card caja fichas">
          {visibles.length > 0 && (
            <div className="scroll">
              <table className="t-gar">
                <caption className="sr">Garantías registradas</caption>
                <thead>
                  <tr>
                    <th scope="col">Serial</th>
                    <th scope="col">Titular</th>
                    <th scope="col">Equipo</th>
                    <th scope="col">Factura</th>
                    <th scope="col">Emitida</th>
                    <th scope="col" aria-sort={asc ? "ascending" : "descending"}>
                      <button type="button" className="ord" onClick={() => setAsc(!asc)}>
                        Vence {asc ? <ArrowUp size={14} strokeWidth={2} aria-hidden="true" /> : <ArrowDown size={14} strokeWidth={2} aria-hidden="true" />}
                      </button>
                    </th>
                    <th scope="col">Estado</th>
                    <th scope="col">
                      <span className="sr">Acción</span>
                    </th>
                  </tr>
                </thead>
                <tbody>
                  {visibles.map(({ g, e }) => (
                    <tr key={g.equipo_id}>
                      <td data-l="Serial">
                        <span className="serie mono">{g.numero_serie}</span>
                      </td>
                      <td data-l="Titular">
                        <div>
                          <div className="p">{g.titular}</div>
                          <div className="s mono">{g.documento}</div>
                        </div>
                      </td>
                      <td data-l="Equipo">
                        <div className="p">{g.producto}</div>
                      </td>
                      <td data-l="Factura">
                        <div>
                          <span className="mono dias">{g.numero_soporte ?? "—"}</span>
                          {g.origen === "TALLER" && (
                            <div>
                              <span className="origen">Registrada en taller</span>
                            </div>
                          )}
                        </div>
                      </td>
                      <td data-l="Emitida">
                        <div className="dias">
                          {fcorta(g.fecha_emision)}
                          {g.plazo_dias && <div className="s">plazo {g.plazo_dias} d</div>}
                        </div>
                      </td>
                      <td data-l="Vence">
                        <div className="dias">
                          {e !== "confirmar" && g.vence_el && (
                            <>
                              {fcorta(g.vence_el)}
                              <div className="s" />
                            </>
                          )}
                          {textoDias(g, e)}
                        </div>
                      </td>
                      <td data-l="Estado">
                        <div className="estado-c">
                          <span className="ins" data-t={ESTADOS[e].t}>
                            <i />
                            {ESTADOS[e].n}
                          </span>
                          <InsigniaVerificacion valor={g.verificacion} compacta />
                        </div>
                      </td>
                      <td data-l="">
                        <button
                          type="button"
                          className="abrir"
                          onClick={() => navigate(`/garantias/consulta?serial=${encodeURIComponent(g.numero_serie)}`)}
                        >
                          Ver<span className="sr"> garantía {g.numero_serie}</span>
                        </button>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
          {filas && visibles.length === 0 && (
            <div className="vacio">
              <ShieldCheck size={34} strokeWidth={1.6} aria-hidden="true" />
              <h3>No hay garantías con esos criterios</h3>
              <p>Revisa el serial, la cédula o RIF y la factura, o quita los filtros. Si el equipo no está registrado, puedes crearlo.</p>
              <button type="button" className="btn principal" onClick={() => navigate("/garantias/nueva")}>
                Registrar garantía
              </button>
            </div>
          )}
          <div className="tpie">
            <span>{filas ? `Mostrando ${visibles.length} de ${filas.length} garantías` : "Cargando…"}</span>
            <span>
              Hoy: <time dateTime={new Date().toISOString().slice(0, 10)}>{new Date().toLocaleDateString("es", { day: "numeric", month: "short", year: "numeric" })}</time>
            </span>
          </div>
        </div>
        <p className="nota">
          El plazo de garantía es de 7 o 15 días desde la emisión de la factura.
          {filas?.length >= LIMITE && ` Se muestran las ${LIMITE} que vencen primero.`}
        </p>
      </section>
    </>
  );
}
