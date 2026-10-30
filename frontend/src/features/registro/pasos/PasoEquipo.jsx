// Paso 1 del asistente "Nuevo registro": el serial (spec §7.1).
// Sirve a la pistola lectora de código de barras: la pistola escribe como
// un teclado y termina con Enter — por eso el campo toma el foco al abrir,
// Enter dispara la búsqueda sin enviar el formulario, y una pausa de
// 400 ms sin teclear la dispara igual (para quien escribe a mano).
import { useEffect, useRef, useState } from "react";
import { buscarEquipo, listarProductos } from "../registroService.js";

const PAUSA_MS = 400;   // spec §7.2 (plan): pausa sin teclear para buscar

// Límites de "falla" (corrección D5): los mismos de la base — CHECK de 5 a
// 2000 caracteres en la tabla ordenes_servicio, y p_falla es OBLIGATORIO.
const FALLA_MIN = 5;
const FALLA_MAX = 2000;

function errorDeFalla(texto) {
  if (texto.trim() === "") return "La falla reportada es obligatoria";
  // La base mide length(btrim(...)): se mide igual para no aceptar relleno.
  const largo = texto.trim().length;
  if (largo < FALLA_MIN || largo > FALLA_MAX) {
    return "La falla va de 5 a 2000 caracteres";
  }
  return null;
}

export default function PasoEquipo({ estado, actualizar }) {
  const [serial, setSerial] = useState(estado?.serial ?? "");
  const [falla, setFalla] = useState(estado?.falla ?? "");
  const [resultados, setResultados] = useState(estado?.equipoEncontrado ?? []);
  const [sinCoincidencias, setSinCoincidencias] = useState(false);
  const [productos, setProductos] = useState(estado?.productos?? []);
  const [marcado, setMarcado] = useState(Boolean(estado?.equipoReutilizado));
  const [fallaTocada, setFallaTocada] = useState(false);
  const errorFalla = fallaTocada ? errorDeFalla(falla) : null;
  const campo = useRef(null);
  const temporizador = useRef(null);

  // El foco al abrir: la pistola escribe donde esté el campo, sin tocar nada.
  useEffect(() => {
    campo.current?.focus();
    return () => clearTimeout(temporizador.current);
  }, []);

  useEffect(() => {
    let vivo = true;
    listarProductos().then((r) => {
      if (vivo && r.ok) setProductos(r.datos);
    });
    return () => {
      vivo = false;
    };
  }, []);

  async function buscar(texto) {
    const t = (texto ?? serial).trim();
    if (t.length < 3) return;
    clearTimeout(temporizador.current);
    const r = await buscarEquipo(t);
    if (r.ok) {
      setResultados(r.datos);
      setSinCoincidencias(r.datos.length === 0);
      if (r.datos.length === 1) {
        // Único equipo con ese serial: se reutiliza tal cual (spec: no se
        // recapturan titular, factura ni plazo).
        const e = r.datos[0];
        marcar(e);
      }
    }
  }

  function marcar(e) {
    setMarcado(true);
    actualizar({
      equipoReutilizado: true,
      equipoId: e.equipo_id,
      productoId: e.producto_id,
      serial: e.numero_serie,
      titular: e.titular,
      venceEl: e.vence_el,
      diasRestantes: e.dias_restantes,
      equipoEncontrado: [e],
      equipoAdvertido: false,
    });
  }

  function alEscribir(e) {
    const v = e.target.value;
    setSerial(v);
    setMarcado(false);
    setSinCoincidencias(false);
    setResultados([]);
    clearTimeout(temporizador.current);
    if (v.trim().length >= 3) {
      temporizador.current = setTimeout(() => buscar(v), PAUSA_MS);
    }
  }

  // La falla se compromete al cambiar cada campo (auto-commit, el mismo patrón
  // de la compra): el estado lleva `falla` siempre al día para el borrador y
  // para el envío. El recorte de longitud va aquí también, porque el cambio
  // puede llegar por vía programática, que ignora maxLength.
  function alEscribirFalla(e) {
    const v = e.target.value.slice(0, FALLA_MAX);
    setFalla(v);
    setFallaTocada(true);
    actualizar({ falla: v });
  }

  async function alPulsar(e) {
    if (e.key === "Enter") {
      // Enter NO envía el formulario: en un asistente avanzaría el paso.
      e.preventDefault();
      await buscar();
    }
  }

  return (
    <div>
      <label htmlFor="serial">
        Serial
        <input
          id="serial"
          ref={campo}
          value={serial}
          onChange={alEscribir}
          onKeyDown={alPulsar}
          placeholder="Escanea el código de barras o escribe el serial"
        />
      </label>

      {/* La falla reportada (corrección D5): obligatoria, de 5 a 2000 caracteres.
          Va en este paso para equipos nuevos y reutilizados por igual, así que
          vive fuera de los bloques condicionales de la búsqueda. */}
      <label htmlFor="falla">
        Falla reportada
        <textarea
          id="falla"
          value={falla}
          maxLength={FALLA_MAX}
          onChange={alEscribirFalla}
          placeholder="Describe lo que le pasa al equipo"
        />
      </label>
      {errorFalla && <p role="alert">{errorFalla}</p>}
      {falla.length >= FALLA_MAX && (
        <p role="status">Llegaste al máximo de {FALLA_MAX} caracteres.</p>
      )}

      {resultados.length > 1 && (
        <div role="alert">
          <p>
            Este serial está registrado como{" "}
            {resultados.map((r) => r.producto).join(" y ")}.
          </p>
          <ul>
            {resultados.map((r) => (
              <li key={r.equipo_id}>
                <button type="button" onClick={() => marcar(r)}>
                  Usar el equipo de {r.producto} — titular {r.titular}
                </button>
              </li>
            ))}
          </ul>
        </div>
      )}

      {resultados.length === 1 && (
        <div>
          <p>
            Titular: {resultados[0].titular}. La garantía vence el {resultados[0].vence_el}
            {typeof resultados[0].dias_restantes === "number"
              ? ` (${resultados[0].dias_restantes > 0 ? `${resultados[0].dias_restantes} días restantes` : "vencida"})`
              : ""}
          </p>
          {resultados[0].ordenes_servicio?.length > 0 && (
            <ul>
              {resultados[0].ordenes_servicio.map((rg) => (
                <li key={rg.numero}>
                  Registro {rg.numero} — {rg.estado}
                </li>
              ))}
            </ul>
          )}
        </div>
      )}

      {sinCoincidencias && (
        <div>
          <p>Equipo nuevo: elige la marca y el modelo del catálogo.</p>
          <label htmlFor="marca">
            Marca
            <select
              id="marca"
              value={(estado?.marca ?? "") || ""}
              onChange={(e) => {
                actualizar({ marca: e.target.value, productoId: null });
              }}
            >
              <option value="">—</option>
              {[...new Map(productos.map((p) => [p.marca, p.marca])).values()].map(
                (m) => (
                  <option key={m} value={m}>
                    {m}
                  </option>
                ),
              )}
            </select>
          </label>
          <label htmlFor="modelo">
            Modelo
            <select
              id="modelo"
              value={estado?.productoId ?? ""}
              disabled={!estado?.marca}
              onChange={(e) => actualizar({ productoId: e.target.value })}
            >
              <option value="">—</option>
              {productos
                .filter((p) => p.marca === estado?.marca)
                .map((p) => (
                  <option key={p.id} value={p.id}>
                    {p.modelo}
                  </option>
                ))}
            </select>
          </label>
        </div>
      )}

      <p hidden={!marcado}>Equipo existente: se reutiliza su titular y su garantía.</p>
    </div>
  );
}