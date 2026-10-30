// Paso 6 del asistente: el resumen (spec §7.1). Repasa todo con un botón
// "Editar" por sección que regresa a ese paso; el Confirmar llama a
// enviarRegistro (registro primero, adjuntos después; reintento con
// "Reintentar adjuntos" si alguna subida falló).
import { useState } from "react";
import { enviarRegistro } from "../enviarRegistro.js";

const SECCIONES = [
  ["equipo", "Equipo", (e) => `${e.serial ?? "—"}${e.productoTexto ? ` — ${e.productoTexto}` : ""}`],
  ["cliente", "Cliente", (e) => e.titular ?? e.clienteNombre ?? "—"],
  ["falla", "Falla", (e) => e.falla ?? "—"],
  ["compra", "Compra", (e) => (e.sinSoporte ? "No trae soporte (por determinar)" : `${e.numeroSoporte ?? "—"} — ${e.fechaEmision ?? "—"} — ${e.plazoDias ? `${e.plazoDias} días` : "—"}`)],
  ["verificacion", "Verificación", (e) => e.cobertura ?? "Se calculará al guardar"],
];

export default function PasoResumen({ estado, irPara, onCreado, userId, actualizar }) {
  const [resultado, setResultado] = useState(null);
  const [enviando, setEnviando] = useState(false);
  const archivos = (estado?.archivosAdjuntos ?? [])
    .filter((a) => !(a.error ?? false))
    .map(({ archivo, tipo, etiqueta }) => ({ archivo, tipo, etiqueta }));

  async function confirmar(reintentar = false) {
    setEnviando(true);
    // Una clave por registro: nace en el primer intento y viaja en el borrador,
    // así un reintento (o reenviar tras cerrar la pestaña) no crea un duplicado.
    const claveEnvio = estado?.claveEnvio ?? crypto.randomUUID();
    if (!estado?.claveEnvio) actualizar?.({ claveEnvio });
    const r = await enviarRegistro({ ...estado, claveEnvio }, archivos, {
      userId,
      registroIdExistente: resultado?.registro?.registro_id,
      pendientesIniciales: reintentar ? (resultado?.pendientes ?? []) : [],
    });
    setEnviando(false);
    if (!r.ok) {
      setResultado(r);
      return;
    }
    if (r.pendientes.length > 0) {
      setResultado({ ...r, reintento: true });
      return;
    }
    setResultado(r);
    onCreado?.(r.registro);
  }

  return (
    <div>
      <dl>
        {SECCIONES.map(([clave, titulo, texto]) => (
          <div key={clave}>
            <dt>
              {titulo}{" "}
              <button
                type="button"
                aria-label={`Editar ${titulo.toLowerCase()}`}
                onClick={() => irPara(clave)}
              >
                Editar
              </button>
            </dt>
            <dd>{texto(estado ?? {})}</dd>
          </div>
        ))}
        <div>
          <dt>
            Adjuntos{" "}
            <button
              type="button"
              aria-label="Editar adjuntos"
              onClick={() => irPara("adjuntos")}
            >
              Editar
            </button>
          </dt>
          <dd>
            <ul>
              {(estado?.archivosAdjuntos ?? [])
                .filter((a) => !(a.error ?? false))
                .map((a) => (
                  <li key={a.id ?? a.archivo?.name}>{a.archivo?.name} ({a.tipo})</li>
                ))}
            </ul>
          </dd>
        </div>
      </dl>

      {resultado?.ok && resultado?.pendientes.length > 0 && (
        <div role="status">
          <p>El registro {resultado.registro?.numero_registro} ya existe; falló la subida de {resultado.pendientes.length} archivo(s).</p>
          <button type="button" onClick={() => confirmar(true)}>
            Reintentar adjuntos
          </button>
        </div>
      )}

      {resultado?.ok && resultado?.pendientes.length === 0 && (
        <p role="status">Registro creado: {resultado.registro?.numero_registro}</p>
      )}

      {resultado && !resultado.ok && (
        <p role="alert">
          {resultado.codigo === "SESION_VENCIDA"
            ? "Tu sesión venció: vuelve a entrar para continuar"
            : (resultado.mensaje ?? "No se pudo registrar. Intenta de nuevo.")}
        </p>
      )}

      {(resultado?.ok || resultado === null) && !(resultado?.ok && resultado?.pendientes.length > 0) && (
        <button type="button" className="nr-principal" onClick={() => confirmar(false)} disabled={enviando}>
          {resultado?.ok ? "Registrar el mismo registro" : "Confirmar y registrar"}
        </button>
      )}
    </div>
  );
}