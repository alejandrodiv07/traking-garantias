// Asistente "Nuevo registro" en ventana (Tarea 17 del plan; spec §7.1).
// La ventana viste los pasos en orden; los pasos concretos se añaden por
// tarea (17: serial · 18: cliente/compra/verificación · 19: adjuntos/resumen).
import { useState } from "react";
import { useAsistente } from "./useAsistente.js";
import PasoEquipo from "./pasos/PasoEquipo.jsx";
import PasoCliente from "./pasos/PasoCliente.jsx";
import PasoCompra from "./pasos/PasoCompra.jsx";
import PasoVerificacion from "./pasos/PasoVerificacion.jsx";
import PasoAdjuntos from "./pasos/PasoAdjuntos.jsx";
import PasoResumen from "./pasos/PasoResumen.jsx";

export default function NuevoRegistro({ userId, onCerrar, onCreado }) {
  const a = useAsistente(userId);
  const [restaurando, setRestaurando] = useState(Boolean(a.borradorOfrecido));

  if (a.borradorOfrecido && restaurando) {
    return (
      <div role="dialog" aria-label="Nuevo registro">
        <p>Tienes un borrador de hace poco. ¿Lo restauras?</p>
        <button
          type="button"
          onClick={() => {
            setRestaurando(false);
            a.restaurar();
          }}
        >
          Restaurar
        </button>
        <button type="button" onClick={() => a.descartarBorrador()}>
          Empezar de cero
        </button>
        <button type="button" onClick={onCerrar}>
          Cerrar
        </button>
      </div>
    );
  }

  const nombres = {
    equipo: "Equipo",
    cliente: "Cliente",
    compra: "Compra",
    verificacion: "Verificación",
    adjuntos: "Adjuntos",
    resumen: "Resumen",
  };

  // Editar <sección> en el resumen regresa al paso correspondiente. La sección
  // "falla" vive en el paso del equipo (no hay paso propio de la falla).
  function pasoDeSeccion(clave) {
    const indice = a.pasos.indexOf(clave);
    return a.ir(indice === -1 ? 0 : indice);
  }

  const pasoActual = a.pasos[a.paso];
  const props = { estado: a.estado, actualizar: a.actualizar };
  return (
    <div role="dialog" aria-label="Nuevo registro">
      <header>
        <h2>Nuevo registro</h2>
        <button type="button" onClick={onCerrar}>
          Cerrar
        </button>
      </header>

      <ol aria-label="Pasos">
        {a.pasos.map((p, i) => (
          <li key={p} aria-current={i === a.paso}>
            <button type="button" onClick={() => a.ir(i)}>
              {nombres[p] ?? p}
            </button>
          </li>
        ))}
      </ol>

      {pasoActual === "equipo" && <PasoEquipo {...props} />}
      {pasoActual === "cliente" && <PasoCliente {...props} />}
      {pasoActual === "compra" && <PasoCompra {...props} />}
      {pasoActual === "verificacion" && <PasoVerificacion {...props} />}
      {pasoActual === "adjuntos" && <PasoAdjuntos {...props} />}
      {pasoActual === "resumen" && (
        <PasoResumen
          estado={a.estado}
          actualizar={a.actualizar}
          irPara={pasoDeSeccion}
          onCreado={onCreado}
          userId={userId}
        />
      )}

      <footer>
        <button type="button" onClick={a.atras} disabled={a.paso === 0}>
          Atrás
        </button>
        <button type="button" onClick={a.siguiente} disabled={a.paso === a.pasos.length - 1}>
          Siguiente
        </button>
      </footer>
    </div>
  );
}