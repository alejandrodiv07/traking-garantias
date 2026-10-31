/**
 * Auditoría de recepción (maqueta 04, paso 3): seis puntos con Sí / No SIN valor
 * por defecto (no confundir «sin responder» con «no cumple») y cinco señales de
 * causas externas que se marcan si se observan. La cobertura la calcula SIEMPRE
 * la base (`calcular_cobertura`): aquí solo se pregunta y se muestra; mientras
 * falte algún punto no se consulta. Si la base no responde, se calcula al guardar.
 */
import { useEffect, useRef, useState } from "react";
import { cobertura as nombreCobertura } from "../tablero/dominio.js";
import { previsualizarCobertura } from "../registro/registroService.js";
import { auditoriaCompleta, checklistParaBase, PUNTOS, SENALES } from "./auditoria.js";

const TONO = { EN_GARANTIA: "ok", ANULADA_POR_USO: "mal", FUERA_DE_GARANTIA: "mal", POR_DETERMINAR: "neutro" };

const hoyISO = () => new Date().toLocaleDateString("sv");

export default function AuditoriaRecepcion({ estado, actualizar }) {
  const [falloPreview, setFalloPreview] = useState(false);
  const temporizador = useRef(null);
  const checklist = estado?.checklist ?? {};

  useEffect(() => () => clearTimeout(temporizador.current), []);

  function cambiar(grupo, item, valor) {
    const nuevo = { ...checklist, [grupo]: { ...(checklist[grupo] ?? {}), [item]: valor } };
    actualizar({ checklist: nuevo });
    clearTimeout(temporizador.current);
    if (!auditoriaCompleta(nuevo)) return;
    temporizador.current = setTimeout(async () => {
      const r = await previsualizarCobertura({
        venceEl: estado?.venceEl ?? null,
        fechaIngreso: hoyISO(), // la fecha de ingreso es el día de hoy: el momento de este ingreso
        checklist: checklistParaBase(nuevo),
      });
      if (r.ok) {
        setFalloPreview(false);
        actualizar({ cobertura: r.datos.cobertura, motivoCobertura: r.datos.motivo });
      } else {
        setFalloPreview(true);
      }
    }, 250);
  }

  const completa = auditoriaCompleta(checklist);
  const c = estado?.cobertura;

  return (
    <div>
      {PUNTOS.map((g) => (
        <fieldset key={g.clave} className="wz-campos">
          <legend>{g.titulo}</legend>
          {g.items.map(([k, texto]) => (
            <div className="wz-fila" key={k} role="radiogroup" aria-label={texto}>
              <span className="q">{texto}</span>
              <div className="seg">
                {[
                  [true, "Sí"],
                  [false, "No"],
                ].map(([v, t]) => (
                  <label key={t}>
                    <input
                      type="radio"
                      name={`${g.clave}-${k}`}
                      checked={checklist[g.clave]?.[k] === v}
                      onChange={() => cambiar(g.clave, k, v)}
                    />
                    <span>{t}</span>
                  </label>
                ))}
              </div>
            </div>
          ))}
        </fieldset>
      ))}

      <fieldset className="wz-campos">
        <legend>Señales de causas externas (marca las que observes)</legend>
        <div className="checks">
          {SENALES.map(([k, texto]) => (
            <label key={k}>
              <input type="checkbox" checked={Boolean(checklist.senales?.[k])} onChange={(e) => cambiar("senales", k, e.target.checked)} />
              <span>{texto}</span>
            </label>
          ))}
        </div>
      </fieldset>

      <p className={c && completa && !falloPreview ? `aviso ${TONO[c] === "mal" ? "mal" : TONO[c] === "ok" ? "ok" : ""}` : "aviso"} role="status" aria-live="polite">
        <span>
          Cobertura:{" "}
          {!completa
            ? "responde los seis puntos para calcularla"
            : falloPreview
              ? "se calculará al guardar"
              : c
                ? `${nombreCobertura(c).nombre}${estado?.motivoCobertura ? ` — ${estado.motivoCobertura}` : ""}`
                : "calculando…"}
        </span>
      </p>
    </div>
  );
}
