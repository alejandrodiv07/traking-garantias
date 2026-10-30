// Formulario de revisión (Tarea 21 del plan; spec §7.4).
// La MISMA lista de verificación que el asistente; el resultado lo calcula
// la base y el formulario lo muestra tal como llega. RECEPCION no revisa.
// Solo anexar: el formulario no ofrece editar ni borrar nada.
import { useState } from "react";
import { registrarRevision } from "./revisionesService.js";

const GRUPOS = [
  {
    clave: "condiciones",
    titulo: "Condiciones del trámite",
    items: [
      ["factura_presentada", "La factura o nota está sin alteraciones"],
      ["titular_coincide", "Quien tramita coincide con el titular de la factura"],
    ],
  },
  {
    clave: "equipo",
    titulo: "Estado del equipo",
    items: [
      ["serial_legible", "El serial de fábrica es legible"],
      ["caja_original", "Caja original"],
      ["precintos_intactos", "Los precintos de seguridad están intactos"],
      ["contenido_completo", "Equipo sin abrir y con todo su contenido"],
    ],
  },
  {
    clave: "senales",
    titulo: "Señales de causas externas",
    items: [
      ["descarga_electrica", "Descarga eléctrica"],
      ["liquidos", "Derrame de líquidos"],
      ["altas_temperaturas", "Altas temperaturas"],
      ["golpes", "Golpes"],
      ["manipulacion_terceros", "Manipulación de terceros"],
    ],
  },
];

export default function RevisionForm({ registroId, rol, onRegistrada }) {
  const [checklist, setChecklist] = useState({});
  const [observaciones, setObservaciones] = useState("");
  const [resultado, setResultado] = useState(null);
  const [error, setError] = useState("");
  const [enviando, setEnviando] = useState(false);

  if (rol === "RECEPCION") {
    return <p role="note">Tu rol no registra revisiones.</p>;
  }

  const tipo = "TECNICA";   // la de recepción la crea registrar_ingreso

  async function enviar() {
    setEnviando(true);
    setError("");
    const r = await registrarRevision(registroId, {
      tipo,
      checklist: { ...checklist },
      observaciones: observaciones.trim() || null,
    });
    setEnviando(false);
    if (r.ok) {
      setResultado(r.datos);
      onRegistrada?.(r.datos);
    } else {
      setError(r.mensaje ?? "No se pudo registrar la revisión");
    }
  }

  return (
    <form
      onSubmit={(e) => {
        e.preventDefault();
        enviar();
      }}
    >
      {GRUPOS.map((g) => (
        <fieldset key={g.clave}>
          <legend>{g.titulo}</legend>
          {g.items.map(([clave, texto]) => (
            <label key={clave}>
              <input
                type="checkbox"
                checked={Boolean(checklist?.[g.clave]?.[clave])}
                onChange={(e) =>
                  setChecklist((c) => ({
                    ...c,
                    [g.clave]: { ...(c?.[g.clave] ?? {}), [clave]: e.target.checked },
                  }))
                }
              />
              {texto}
            </label>
          ))}
        </fieldset>
      ))}

      <label htmlFor="observaciones">
        Observaciones
        <textarea
          id="observaciones"
          value={observaciones}
          onChange={(e) => setObservaciones(e.target.value)}
        />
      </label>

      <button type="submit" disabled={enviando}>
        Guardar revisión
      </button>

      {resultado && (
        <p role="status">Revisión guardada. Cobertura del registro: {resultado.cobertura}</p>
      )}
      {error && <p role="alert">{error}</p>}
    </form>
  );
}