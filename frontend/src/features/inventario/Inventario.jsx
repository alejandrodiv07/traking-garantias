/**
 * Inventario (maqueta 06, /inventario): el catálogo de productos de Prime
 * Telecom — marcas, modelos y tipos de equipo — que alimenta los selectores de
 * Nueva garantía. Lo lee cualquier rol interno; ADMIN y JEFE_SERVICIO agregan,
 * corrigen el tipo y desactivan modelos (un modelo con garantías no se borra:
 * se desactiva y deja de ofrecerse). Las existencias (stock) y los repuestos
 * llegan con su propio backend: hoy el catálogo solo dice QUÉ se vende.
 */
import { useEffect, useState } from "react";
import { Package, Plus, Search, X } from "lucide-react";
import { useAuth } from "../auth/AuthContext.jsx";
import { actualizarProducto, cambiarActivo, crearProducto, listarCatalogo } from "./inventarioService.js";
import "./inventario.css";

const ROLES_JEFATURA = ["ADMIN", "JEFE_SERVICIO"];
const PAGINA = 100;
const VACIO = { marca: "", modelo: "", categoria: "", meses: "12" };

const norm = (s) => String(s ?? "").toUpperCase().replace(/[\s-]/g, "");

function Formulario({ inicial, editando, marcas, tipos, onGuardar, onCancelar, enviando, error }) {
  const [f, setF] = useState(inicial);
  const meses = Number(f.meses);
  const valido =
    f.marca.trim().length >= 2 && f.modelo.trim().length >= 1 && f.categoria.trim().length >= 2 && Number.isInteger(meses) && meses >= 0 && meses <= 120;

  return (
    <form
      className="card inv-form"
      aria-label={editando ? "Editar modelo" : "Nuevo producto"}
      onSubmit={(ev) => {
        ev.preventDefault();
        if (valido) onGuardar(f);
      }}
    >
      <h2>{editando ? `Editar ${inicial.marca} ${inicial.modelo}` : "Nuevo producto"}</h2>
      <p className="wz-ayuda">
        {editando ? "Corrige el tipo de equipo o la garantía del fabricante." : "Si la marca no existe, se crea con el modelo."}
      </p>
      <div className="wz-cols">
        <div className="wz-f">
          <label htmlFor="inv-marca">Marca</label>
          <input id="inv-marca" className="campo" list="inv-marcas" autoComplete="off" value={f.marca} disabled={editando} onChange={(e) => setF({ ...f, marca: e.target.value })} />
          <datalist id="inv-marcas">
            {marcas.map((m) => (
              <option key={m} value={m} />
            ))}
          </datalist>
        </div>
        <div className="wz-f">
          <label htmlFor="inv-modelo">Modelo</label>
          <input id="inv-modelo" className="campo mono" autoComplete="off" maxLength={80} value={f.modelo} disabled={editando} onChange={(e) => setF({ ...f, modelo: e.target.value })} />
        </div>
        <div className="wz-f">
          <label htmlFor="inv-tipo">Tipo de equipo</label>
          <input id="inv-tipo" className="campo" list="inv-tipos" autoComplete="off" value={f.categoria} onChange={(e) => setF({ ...f, categoria: e.target.value })} />
          <datalist id="inv-tipos">
            {tipos.map((t) => (
              <option key={t} value={t} />
            ))}
          </datalist>
        </div>
        <div className="wz-f">
          <label htmlFor="inv-meses">Garantía del fabricante (meses)</label>
          <input id="inv-meses" type="number" min="0" max="120" className="campo" value={f.meses} onChange={(e) => setF({ ...f, meses: e.target.value })} aria-invalid={!Number.isInteger(meses) || meses < 0 || meses > 120} />
        </div>
      </div>
      {error && (
        <p role="alert" className="aviso mal">
          {error}
        </p>
      )}
      <div className="inv-form-bt">
        <button type="submit" className="btn principal" disabled={!valido || enviando}>
          {enviando ? "Guardando…" : editando ? "Guardar cambios" : "Agregar producto"}
        </button>
        <button type="button" className="btn suave" onClick={onCancelar}>
          Cancelar
        </button>
      </div>
    </form>
  );
}

export default function Inventario() {
  const { rol } = useAuth();
  const jefatura = ROLES_JEFATURA.includes(rol);
  const [filas, setFilas] = useState(null);
  const [error, setError] = useState(null);
  const [q, setQ] = useState("");
  const [marca, setMarca] = useState("");
  const [tipo, setTipo] = useState("");
  const [chip, setChip] = useState("activos");
  const [limite, setLimite] = useState(PAGINA);
  const [form, setForm] = useState(null); // null | { editando: fila | null }
  const [enviando, setEnviando] = useState(false);
  const [errorForm, setErrorForm] = useState(null);
  const [aviso, setAviso] = useState(null);
  const editando = form?.editando ?? null; // el compilador de React lo lee al renderizar: con form nulo, null

  async function cargar() {
    const r = await listarCatalogo();
    if (r.ok) {
      setFilas(r.datos);
      setError(null);
    } else {
      setError(r.mensaje || "No se pudo cargar el catálogo");
    }
  }

  useEffect(() => {
    let vivo = true;
    listarCatalogo().then((r) => {
      if (!vivo) return;
      if (r.ok) setFilas(r.datos);
      else setError(r.mensaje || "No se pudo cargar el catálogo");
    });
    return () => {
      vivo = false;
    };
  }, []);

  const todas = filas ?? [];
  const marcas = [...new Set(todas.map((p) => p.marca))].sort((a, b) => a.localeCompare(b));
  const tipos = [...new Set(todas.map((p) => p.categoria))].sort((a, b) => a.localeCompare(b));
  const buscado = norm(q);
  const base = todas.filter(
    (p) => (!marca || p.marca === marca) && (!tipo || p.categoria === tipo) && (!buscado || norm(p.marca + p.modelo + p.categoria).includes(buscado)),
  );
  const cuenta = { activos: base.filter((p) => p.activo).length, inactivos: base.filter((p) => !p.activo).length, todos: base.length };
  const visibles = base.filter((p) => chip === "todos" || (chip === "activos" ? p.activo : !p.activo));
  const mostrados = visibles.slice(0, limite);

  const activos = todas.filter((p) => p.activo);

  async function guardar(f) {
    setEnviando(true);
    setErrorForm(null);
    const r = editando
      ? await actualizarProducto(editando.id, { categoria: f.categoria, meses: f.meses })
      : await crearProducto({ marca: f.marca, modelo: f.modelo, categoria: f.categoria, meses: f.meses });
    setEnviando(false);
    if (!r.ok) return setErrorForm(r.mensaje || "No se pudo guardar");
    setAviso(editando ? "Cambios guardados" : `${f.marca.trim()} ${f.modelo.trim()} agregado al catálogo`);
    setForm(null);
    cargar();
  }

  async function alternar(p) {
    setAviso(null);
    const r = await cambiarActivo(p.id, !p.activo);
    if (r.ok) {
      setAviso(`${p.marca} ${p.modelo} ${p.activo ? "desactivado: ya no se ofrece al registrar garantías" : "activado"}`);
      cargar();
    } else {
      setError(r.mensaje || "No se pudo cambiar el estado");
    }
  }

  return (
    <>
      <div className="enc">
        <div>
          <h1>Inventario</h1>
          {filas && (
            <p className="sub">
              {activos.length} modelos activos de {marcas.length} marcas · catálogo de Prime Telecom
            </p>
          )}
        </div>
        {jefatura && !form && (
          <button
            type="button"
            className="btn principal"
            onClick={() => {
              setForm({ editando: null });
              setErrorForm(null);
              setAviso(null);
            }}
          >
            <Plus size={17} strokeWidth={2.4} aria-hidden="true" />
            Nuevo producto
          </button>
        )}
      </div>

      <ul className="kpis">
        <li className="card kpi">
          <h2>Modelos activos</h2>
          <p className="v">{activos.length}</p>
          <p className="n">se ofrecen al registrar</p>
        </li>
        <li className="card kpi">
          <h2>Marcas</h2>
          <p className="v">{marcas.length}</p>
          <p className="n">en el catálogo</p>
        </li>
        <li className="card kpi">
          <h2>Tipos de equipo</h2>
          <p className="v">{tipos.length}</p>
          <p className="n">routers, UPS, monitores…</p>
        </li>
        <li className="card kpi ambar">
          <h2>Desactivados</h2>
          <p className="v">{todas.length - activos.length}</p>
          <p className="n">no se ofrecen, se conservan</p>
        </li>
      </ul>

      {aviso && (
        <p role="status" className="aviso ok">
          {aviso}
        </p>
      )}

      {form && (
        <Formulario
          key={editando?.id ?? "nuevo"}
          inicial={editando ? { marca: editando.marca, modelo: editando.modelo, categoria: editando.categoria, meses: String(editando.meses_garantia) } : VACIO}
          editando={Boolean(editando)}
          marcas={marcas}
          tipos={tipos}
          enviando={enviando}
          error={errorForm}
          onGuardar={guardar}
          onCancelar={() => setForm(null)}
        />
      )}

      <section aria-label="Catálogo de productos">
        <div className="filtros inv-filtros">
          <div className="buscar">
            <label className="sr" htmlFor="inv-q">
              Buscar por marca, modelo o tipo
            </label>
            <Search className="lupa" size={18} aria-hidden="true" />
            <input id="inv-q" className="campo" type="search" autoComplete="off" placeholder="Buscar por marca, modelo o tipo…" value={q} onChange={(e) => { setQ(e.target.value); setLimite(PAGINA); }} />
            {q && (
              <button type="button" className="limpiar" aria-label="Borrar la búsqueda" onClick={() => setQ("")}>
                <X size={16} strokeWidth={2} aria-hidden="true" />
              </button>
            )}
          </div>
          <div className="fecha">
            <label htmlFor="inv-f-marca">Marca</label>
            <select id="inv-f-marca" className="campo" value={marca} onChange={(e) => { setMarca(e.target.value); setLimite(PAGINA); }}>
              <option value="">Todas</option>
              {marcas.map((m) => (
                <option key={m} value={m}>
                  {m}
                </option>
              ))}
            </select>
          </div>
          <div className="fecha">
            <label htmlFor="inv-f-tipo">Tipo de equipo</label>
            <select id="inv-f-tipo" className="campo" value={tipo} onChange={(e) => { setTipo(e.target.value); setLimite(PAGINA); }}>
              <option value="">Todos</option>
              {tipos.map((t) => (
                <option key={t} value={t}>
                  {t}
                </option>
              ))}
            </select>
          </div>
        </div>

        <div className="chips" role="group" aria-label="Filtrar por estado">
          {[
            ["activos", "Activos"],
            ["inactivos", "Desactivados"],
            ["todos", "Todos"],
          ].map(([k, n]) => (
            <button key={k} type="button" className="chip" aria-pressed={chip === k} onClick={() => { setChip(k); setLimite(PAGINA); }}>
              {n} <span className="q">{cuenta[k]}</span>
            </button>
          ))}
        </div>
        <p className="sr" role="status" aria-live="polite">
          {filas ? `${visibles.length} modelos` : ""}
        </p>

        {error && (
          <p role="alert" className="aviso-error">
            {error}
          </p>
        )}

        <div className="card caja fichas">
          {mostrados.length > 0 && (
            <div className="scroll">
              <table>
                <caption className="sr">Catálogo de productos</caption>
                <thead>
                  <tr>
                    <th scope="col">Marca</th>
                    <th scope="col">Modelo</th>
                    <th scope="col">Tipo de equipo</th>
                    <th scope="col">Garantía fabricante</th>
                    <th scope="col">Estado</th>
                    {jefatura && (
                      <th scope="col">
                        <span className="sr">Acciones</span>
                      </th>
                    )}
                  </tr>
                </thead>
                <tbody>
                  {mostrados.map((p) => (
                    <tr key={p.id}>
                      <td data-l="Marca">
                        <span className="p">{p.marca}</span>
                      </td>
                      <td data-l="Modelo">
                        <span className="serie mono">{p.modelo}</span>
                      </td>
                      <td data-l="Tipo">{p.categoria}</td>
                      <td data-l="Garantía">{p.meses_garantia} meses</td>
                      <td data-l="Estado">
                        <span className="ins" data-t={p.activo ? "ok" : "neutro"}>
                          <i />
                          {p.activo ? "Activo" : "Desactivado"}
                        </span>
                      </td>
                      {jefatura && (
                        <td data-l="">
                          <div className="inv-acc">
                            <button type="button" className="abrir" onClick={() => { setForm({ editando: p }); setErrorForm(null); setAviso(null); }}>
                              Editar<span className="sr"> {p.marca} {p.modelo}</span>
                            </button>
                            <button type="button" className="abrir" onClick={() => alternar(p)}>
                              {p.activo ? "Desactivar" : "Activar"}
                              <span className="sr"> {p.marca} {p.modelo}</span>
                            </button>
                          </div>
                        </td>
                      )}
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
          {filas && visibles.length === 0 && (
            <div className="vacio">
              <Package size={34} strokeWidth={1.6} aria-hidden="true" />
              <h3>No hay modelos con esos criterios</h3>
              <p>Cambia los filtros o la búsqueda.{jefatura ? " Si el modelo no está, agrégalo con «Nuevo producto»." : ""}</p>
            </div>
          )}
          <div className="tpie">
            <span>{filas ? `Mostrando ${mostrados.length} de ${visibles.length} modelos` : "Cargando…"}</span>
            {mostrados.length < visibles.length && (
              <button type="button" className="btn chico suave" onClick={() => setLimite(limite + PAGINA)}>
                Mostrar {Math.min(PAGINA, visibles.length - mostrados.length)} más
              </button>
            )}
          </div>
        </div>
        <p className="nota">
          Este catálogo es el que ofrece «Nueva garantía» (solo los activos). Las existencias (stock) y los repuestos del taller llegan cuando tengan su
          propio backend.{!jefatura && " Agregar o desactivar modelos lo hace Jefatura o Administración."}
        </p>
      </section>
    </>
  );
}
