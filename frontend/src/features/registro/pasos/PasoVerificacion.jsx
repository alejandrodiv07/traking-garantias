// Paso 4 del asistente: la verificación (lista del spec §4.3) con el
// resultado EN VIVO. La cobertura SIEMPRE la calcula la base
// (calcular_cobertura vía previsualizarCobertura): el navegador nunca la
// decide, solo la muestra. Si la base no responde, se anuncia que se
// calculará al guardar y el paso sigue funcionando.
import { useEffect, useRef, useState } from "react";
import { previsualizarCobertura } from "../registroService.js";

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
      ["precintos_intactos", "Los precintos de seguridad han de estar intactos"],
      ["contenido_completo", "El equipo no fue abierto y está todo su contenido"],
    ],
  },
  {
    clave: "senales",
    titulo: "Señales de causas externas (marca las que observes)",
    items: [
      ["descarga_electrica", "Descarga eléctrica"],
      ["liquidos", "Derrame de líquidos"],
      ["altas_temperaturas", "Altas temperaturas"],
      ["golpes", "Golpes"],
      ["manipulacion_terceros", "Manipulación de terceros"],
    ],
  },
];

/** El día de hoy (AAAA-MM-DD) en la zona horaria del navegador. */
function hoyISO() {
  const d = new Date();
  const dos = (n) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${dos(d.getMonth() + 1)}-${dos(d.getDate())}`;
}

/** El checklist completo: todas las casillas de los 3 grupos con booleanos. */
function checklistCompleto(marcado) {
  const completo = {};
  for (const g of GRUPOS) {
    completo[g.clave] = {};
    for (const [item] of g.items) {
      completo[g.clave][item] = Boolean(marcado?.[g.clave]?.[item]);
    }
  }
  return completo;
}

export default function PasoVerificacion({ estado, actualizar }) {
  const [cobertura, setCobertura] = useState(estado?.cobertura ?? null);
  const [motivo, setMotivo] = useState(estado?.motivoCobertura ?? null);
  const [falloPreview, setFalloPreview] = useState(false);
  const temporizador = useRef(null);

  const checklist = estado?.checklist ?? {};
  const alCoberturaEnVista = async (c) => {
    clearTimeout(temporizador.current);
    temporizador.current = setTimeout(async () => {
      const r = await previsualizarCobertura({
        venceEl: estado?.venceEl ?? null,
        // La fecha de ingreso es EL DÍA DE HOY: el momento de este ingreso.
        fechaIngreso: hoyISO(),
        checklist: c,
      });
      if (r.ok) {
        setCobertura(r.datos.cobertura);
        setMotivo(r.datos.motivo);
        setFalloPreview(false);
        actualizar({ checklist: c, cobertura: r.datos.cobertura, motivoCobertura: r.datos.motivo });
      } else {
        setFalloPreview(true);
        actualizar({ checklist: c });
      }
    }, 250);
  };

  useEffect(() => () => clearTimeout(temporizador.current), []);

  function alCambiar(clave, item, marcado) {
    // El checklist que viaja a la base es COMPLETO: todas las casillas de los
    // 3 grupos con booleanos (sin marcar = false). Se inicializa todo en
    // false y esta casilla alterna la suya.
    const marcadoAhora = {
      ...checklist,
      [clave]: { ...(checklist?.[clave] ?? {}), [item]: marcado },
    };
    alCoberturaEnVista(checklistCompleto(marcadoAhora));
  }

  return (
    <div>
      {GRUPOS.map((g) => (
        <fieldset key={g.clave}>
          <legend>{g.titulo}</legend>
          {g.items.map(([clave, texto]) => (
            <label key={clave}>
              <input
                type="checkbox"
                checked={Boolean(checklist?.[g.clave]?.[clave])}
                onChange={(e) => alCambiar(g.clave, clave, e.target.checked)}
              />
              {texto}
            </label>
          ))}
        </fieldset>
      ))}

      <p aria-live="polite">
        Cobertura:{" "}
        {falloPreview
          ? "Se calculará al guardar"
          : cobertura
            ? `${cobertura}${motivo ? ` — ${motivo}` : ""}`
            : "…"}
      </p>
    </div>
  );
}