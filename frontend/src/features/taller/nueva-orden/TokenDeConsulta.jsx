/**
 * Entrega del token de consulta (§7.3). Requisito funcional, no un extra:
 * `crear_orden()` devuelve el token en claro EXACTAMENTE una vez; en la
 * base solo queda su SHA-256, y nadie -ni el ADMIN, ni el SQL Editor, ni
 * `service_role`- puede recuperarlo después.
 *
 * Esta pantalla también es donde se suben los documentos pendientes
 * (ADR-012): ocurre ANTES de revelar el token, así que un fallo de subida
 * se nota mientras el usuario todavía está mirando la pantalla y no
 * distraído con el comprobante.
 *
 * Reglas que esta pantalla no puede romper:
 *   - el token no se guarda en localStorage, ni se pasa a console.*, ni
 *     viaja a ningún otro sitio;
 *   - cerrar pide confirmación explícita;
 *   - recargar la página no lo devuelve (no hay forma de "recuperarlo": si
 *     se pierde, la salida es `regenerar_token_orden`, ADR-011, que queda
 *     fuera de esta pantalla y de esta fase).
 */
import { useEffect, useRef, useState } from "react";
import { Check, Copy, TriangleAlert } from "lucide-react";
import { subirDocumentos } from "../datos/documentos.js";

export default function TokenDeConsulta({ resultado, pendientesDocumentos, usuarioId, onCerrar }) {
  const [subiendo, setSubiendo] = useState(pendientesDocumentos.length > 0);
  const [resultadosSubida, setResultadosSubida] = useState([]);
  const [copiado, setCopiado] = useState(false);
  const [pidiendoConfirmacion, setPidiendoConfirmacion] = useState(false);
  const yaSubioRef = useRef(false);

  useEffect(() => {
    if (yaSubioRef.current || pendientesDocumentos.length === 0) return;
    yaSubioRef.current = true;
    subirDocumentos({
      ordenId: resultado.ordenId,
      pendientes: pendientesDocumentos,
      usuarioId,
    }).then((resultados) => {
      setResultadosSubida(resultados);
      setSubiendo(false);
    });
  }, [resultado.ordenId, pendientesDocumentos, usuarioId]);

  async function copiar() {
    try {
      await navigator.clipboard.writeText(resultado.consultaToken);
      setCopiado(true);
      setTimeout(() => setCopiado(false), 2000);
    } catch {
      // Portapapeles bloqueado (contexto no seguro, permiso denegado): el
      // token sigue seleccionable a mano en el <code>, así que no es un
      // callejón sin salida.
    }
  }

  const fallidos = resultadosSubida.filter((r) => !r.ok);

  return (
    <div className="no-token">
      <h3 className="no-token-titulo">Orden {resultado.numeroOrden} creada</h3>

      {subiendo ? (
        <p className="no-token-subiendo" role="status" aria-live="polite">
          Subiendo {pendientesDocumentos.length}{" "}
          {pendientesDocumentos.length === 1 ? "documento" : "documentos"}…
        </p>
      ) : fallidos.length > 0 ? (
        <div className="no-token-aviso-fallo" role="alert">
          <TriangleAlert size={16} strokeWidth={2} aria-hidden="true" />
          <p>
            La orden se creó correctamente, pero {fallidos.length === 1 ? "un documento" : `${fallidos.length} documentos`} no
            se pudo{fallidos.length === 1 ? "" : "n"} subir: {fallidos.map((f) => f.nombreArchivo).join(", ")}.
            Puedes reintentarlo más tarde desde la ficha de la orden.
          </p>
        </div>
      ) : resultadosSubida.length > 0 ? (
        <p className="no-token-ok">
          <Check size={15} strokeWidth={2.5} aria-hidden="true" /> {resultadosSubida.length}{" "}
          {resultadosSubida.length === 1 ? "documento subido" : "documentos subidos"}.
        </p>
      ) : null}

      <div className="no-token-caja">
        <p className="no-token-etiqueta">Código de consulta del cliente</p>
        <div className="no-token-valor">
          <code>{resultado.consultaToken}</code>
          <button type="button" className="tg-btn tg-btn--suave tg-btn--icono" onClick={copiar} aria-label="Copiar código">
            {copiado ? <Check size={16} strokeWidth={2.5} aria-hidden="true" /> : <Copy size={16} strokeWidth={1.8} aria-hidden="true" />}
          </button>
        </div>
        <p className="no-token-advertencia">
          <TriangleAlert size={14} strokeWidth={2} aria-hidden="true" /> Este código no se puede volver a
          mostrar. Anótalo o imprímelo antes de cerrar.
        </p>
      </div>

      {pidiendoConfirmacion ? (
        <div className="no-token-confirmar" role="alertdialog" aria-label="Confirmar cierre">
          <p>¿Ya anotaste o imprimiste el código? No podrás volver a verlo.</p>
          <div className="no-token-confirmar-acciones">
            <button type="button" className="tg-btn tg-btn--suave" onClick={() => setPidiendoConfirmacion(false)}>
              Volver
            </button>
            <button type="button" className="tg-btn tg-btn--principal" onClick={onCerrar}>
              Sí, cerrar
            </button>
          </div>
        </div>
      ) : (
        <button
          type="button"
          className="tg-btn tg-btn--principal no-token-cerrar"
          onClick={() => setPidiendoConfirmacion(true)}
        >
          Cerrar
        </button>
      )}
    </div>
  );
}
