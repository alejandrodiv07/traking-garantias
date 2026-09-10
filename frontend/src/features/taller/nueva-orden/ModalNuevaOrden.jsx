/**
 * Modal de alta de orden (§7 y §7.3). Foco atrapado, `Esc` cierra (salvo en
 * la pantalla de token, donde cerrar exige la confirmación explícita que
 * ya vive en `TokenDeConsulta.jsx` -- perder de vista un token de un solo
 * uso por un `Esc` accidental no es aceptable), `aria-modal` + rol de
 * diálogo para que un lector de pantalla anuncie que el resto de la
 * página queda inerte.
 *
 * No se cierra al crear la orden con éxito (§7.3): cambia a la vista de
 * token. El cierre real de la ventana lo decide `TokenDeConsulta`.
 */
import { useEffect, useRef, useState } from "react";
import { X } from "lucide-react";
import { sileo } from "sileo";
import { useAuth } from "../../auth/AuthContext.jsx";
import { crearOrden } from "../datos/ordenes.js";
import FormularioOrden from "./FormularioOrden.jsx";
import TokenDeConsulta from "./TokenDeConsulta.jsx";
import "./NuevaOrden.css";

const SELECTOR_FOCUSABLES =
  'a[href], button:not([disabled]), textarea, input, select, [tabindex]:not([tabindex="-1"])';

export default function ModalNuevaOrden({ onCerrar, onOrdenCreada }) {
  const { perfil } = useAuth();
  const [vista, setVista] = useState("formulario"); // 'formulario' | 'token'
  const [resultado, setResultado] = useState(null);
  const [documentosPendientes, setDocumentosPendientes] = useState([]);
  const [enviando, setEnviando] = useState(false);
  const [errorEnvio, setErrorEnvio] = useState(null);
  const cajaRef = useRef(null);

  useEffect(() => {
    const anterior = document.activeElement;
    const primero = cajaRef.current?.querySelector(SELECTOR_FOCUSABLES);
    primero?.focus();
    return () => {
      if (anterior instanceof HTMLElement) anterior.focus();
    };
  }, []);

  useEffect(() => {
    function alTeclado(evento) {
      if (evento.key === "Escape" && vista === "formulario") {
        evento.stopPropagation();
        onCerrar();
      } else if (evento.key === "Tab") {
        const foco = cajaRef.current?.querySelectorAll(SELECTOR_FOCUSABLES);
        if (!foco || foco.length === 0) return;
        const primero = foco[0];
        const ultimo = foco[foco.length - 1];
        if (evento.shiftKey && document.activeElement === primero) {
          evento.preventDefault();
          ultimo.focus();
        } else if (!evento.shiftKey && document.activeElement === ultimo) {
          evento.preventDefault();
          primero.focus();
        }
      }
    }
    document.addEventListener("keydown", alTeclado, true);
    return () => document.removeEventListener("keydown", alTeclado, true);
  }, [vista, onCerrar]);

  async function alCrear({ datosOrden, documentosPendientes: pendientes }) {
    setEnviando(true);
    setErrorEnvio(null);
    const respuesta = await crearOrden(datosOrden);
    setEnviando(false);

    if (!respuesta.ok) {
      setErrorEnvio(respuesta.error.mensaje);
      return;
    }

    setResultado(respuesta.datos);
    setDocumentosPendientes(pendientes);
    setVista("token");
    onOrdenCreada?.();

    sileo.success({
      title: "Garantía registrada",
      description: respuesta.datos?.numeroOrden
        ? `Orden ${respuesta.datos.numeroOrden} creada correctamente.`
        : "La orden se creó correctamente.",
    });
  }

  return (
    <div className="no-superposicion" onMouseDown={(e) => e.target === e.currentTarget && vista === "formulario" && onCerrar()}>
      <div
        className="no-caja"
        role="dialog"
        aria-modal="true"
        aria-labelledby="no-titulo"
        ref={cajaRef}
      >
        <header className="no-cabecera">
          <div>
            <p className="no-cabecera-ruta">TALLER · NUEVA ORDEN</p>
            <h2 className="no-cabecera-titulo" id="no-titulo">
              {vista === "formulario" ? "Registrar orden de servicio" : "Comprobante de la orden"}
            </h2>
          </div>
          {vista === "formulario" ? (
            <button type="button" className="no-cerrar" aria-label="Cerrar" onClick={onCerrar}>
              <X size={18} strokeWidth={1.8} aria-hidden="true" />
            </button>
          ) : null}
        </header>

        <div className="no-cuerpo">
          {vista === "formulario" ? (
            <>
              {errorEnvio ? (
                <p className="no-error-envio" role="alert">
                  {errorEnvio}
                </p>
              ) : null}
              <FormularioOrden onCrear={alCrear} onCancelar={onCerrar} enviando={enviando} />
            </>
          ) : (
            <TokenDeConsulta
              resultado={resultado}
              pendientesDocumentos={documentosPendientes}
              usuarioId={perfil?.id}
              onCerrar={onCerrar}
            />
          )}
        </div>
      </div>
    </div>
  );
}
