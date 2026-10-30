/**
 * Registrar la garantía de la venta (spec §8, Tarea 13): cliente → equipo →
 * compra → resumen. Sin orden, sin checklist, sin fotos: revisar el equipo es
 * cosa del Taller. Reutiliza PasoCliente y PasoCompra del Hito 1 por props.
 * La base decide los permisos; el aviso del plazo solo adelanta su respuesta.
 */
import { useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import { useAuth } from "../auth/AuthContext.jsx";
import PasoCliente from "../registro/pasos/PasoCliente.jsx";
import PasoCompra from "../registro/pasos/PasoCompra.jsx";
import { listarProductos } from "../registro/registroService.js";
import { registrarGarantia } from "./garantiasService.js";
import "./garantias.css";

const PASOS = ["Cliente", "Equipo", "Compra", "Resumen"];
const PLAZOS_LIBRES = [7, 15];
const ROLES_JEFATURA = ["ADMIN", "JEFE_SERVICIO"];

const nombreMarca = (p) => p.marca?.nombre ?? p.marca;

function PasoEquipoGarantia({ estado, actualizar }) {
  const [productos, setProductos] = useState([]);
  useEffect(() => {
    let vivo = true;
    listarProductos().then((r) => vivo && r.ok && setProductos(r.datos));
    return () => {
      vivo = false;
    };
  }, []);

  const marcas = [...new Set(productos.map(nombreMarca))];
  return (
    <div className="ng-campos">
      <label htmlFor="serial">
        Serial
        <input
          id="serial"
          value={estado.serial ?? ""}
          onChange={(e) => actualizar({ serial: e.target.value })}
          placeholder="Escanea el código de barras o escribe el serial"
          autoComplete="off"
        />
      </label>
      <label htmlFor="marca">
        Marca
        <select
          id="marca"
          value={estado.marca ?? ""}
          onChange={(e) => actualizar({ marca: e.target.value, productoId: null, productoTexto: null })}
        >
          <option value="">—</option>
          {marcas.map((m) => (
            <option key={m} value={m}>
              {m}
            </option>
          ))}
        </select>
      </label>
      <label htmlFor="modelo">
        Modelo
        <select
          id="modelo"
          value={estado.productoId ?? ""}
          disabled={!estado.marca}
          onChange={(e) => {
            const p = productos.find((x) => x.id === e.target.value);
            actualizar({
              productoId: e.target.value || null,
              productoTexto: p ? `${nombreMarca(p)} ${p.modelo}` : null,
            });
          }}
        >
          <option value="">—</option>
          {productos
            .filter((p) => nombreMarca(p) === estado.marca)
            .map((p) => (
              <option key={p.id} value={p.id}>
                {p.modelo}
              </option>
            ))}
        </select>
      </label>
    </div>
  );
}

const completo = {
  0: (e) => Boolean(e.clienteId),
  1: (e) => (e.serial ?? "").trim().length >= 3 && Boolean(e.productoId),
  2: () => true,
};

export default function NuevaGarantia({ origen = "VENTA" }) {
  const { rol } = useAuth();
  const navigate = useNavigate();
  const [paso, setPaso] = useState(0);
  const [estado, setEstado] = useState({});
  const [enviando, setEnviando] = useState(false);
  const [error, setError] = useState(null);

  const actualizar = (parcial) => setEstado((s) => ({ ...s, ...parcial }));
  const avisoPlazo =
    estado.plazoDias != null &&
    !PLAZOS_LIBRES.includes(estado.plazoDias) &&
    !ROLES_JEFATURA.includes(rol);

  async function registrar() {
    setEnviando(true);
    setError(null);
    const serial = estado.serial.trim();
    const r = await registrarGarantia({
      clienteId: estado.clienteId,
      productoId: estado.productoId,
      serial,
      tipoSoporte: estado.tipoSoporte,
      numeroSoporte: estado.numeroSoporte,
      fechaEmision: estado.fechaEmision,
      plazoDias: estado.plazoDias,
      origen,
    });
    setEnviando(false);
    if (r.ok) navigate(`/garantias/consulta?serial=${encodeURIComponent(serial)}`);
    else setError(r.mensaje || "No se pudo registrar la garantía");
  }

  return (
    <section className="ng">
      <h1>Nueva garantía</h1>
      <ol className="ng-pasos" aria-label="Pasos">
        {PASOS.map((p, i) => (
          <li key={p} aria-current={i === paso ? "step" : undefined}>
            {p}
          </li>
        ))}
      </ol>

      {paso === 0 && <PasoCliente estado={estado} actualizar={actualizar} />}
      {paso === 1 && <PasoEquipoGarantia estado={estado} actualizar={actualizar} />}
      {paso === 2 && <PasoCompra estado={estado} actualizar={actualizar} />}
      {paso === 2 && avisoPlazo && (
        <p role="status">Solo el jefe puede fijar ese plazo; la base rechazará el registro.</p>
      )}
      {paso === 3 && (
        <dl className="ng-resumen">
          <dt>Cliente</dt>
          <dd>{estado.clienteNombre}</dd>
          <dt>Equipo</dt>
          <dd>
            {estado.serial} — {estado.productoTexto}
          </dd>
          <dt>Compra</dt>
          <dd>
            {estado.sinSoporte || !estado.numeroSoporte
              ? "Sin soporte de compra"
              : `${estado.numeroSoporte} — ${estado.fechaEmision ?? "—"} — ${estado.plazoDias ?? "—"} días`}
          </dd>
        </dl>
      )}
      {error && <p role="alert">{error}</p>}

      <footer className="ng-pie">
        <button type="button" onClick={() => setPaso(paso - 1)} disabled={paso === 0}>
          Atrás
        </button>
        {paso < 3 ? (
          <button type="button" onClick={() => setPaso(paso + 1)} disabled={!completo[paso](estado)}>
            Siguiente
          </button>
        ) : (
          <button type="button" className="ng-principal" onClick={registrar} disabled={enviando}>
            Registrar garantía
          </button>
        )}
      </footer>
    </section>
  );
}
