/**
 * Modal de "Agregar nueva garantía" -- reemplaza a `ModalNuevaOrden.jsx`.
 * Mismo contrato de foco/teclado que el original (foco atrapado, `Esc`
 * cierra salvo en la pantalla de token, `aria-modal` + rol de diálogo);
 * lo único que cambia es qué formulario envuelve (`FormularioGarantia`,
 * el asistente de 4 pasos) y el texto visible.
 *
 * Sigue llamando a `crearOrden()` -- "garantía" y "orden" son la misma
 * fila de `public.garantias`; el nombre de la función no cambia porque el
 * resto del código ya la usa así.
 */
import { useEffect, useRef, useState } from "react";
import { X } from "lucide-react";
import { sileo } from "sileo";
import { useAuth } from "../../auth/AuthContext.jsx";
import { crearOrden } from "../datos/ordenes.js";
import FormularioGarantia from "./FormularioGarantia.jsx";
import TokenDeConsulta from "./TokenDeConsulta.jsx";
import "./NuevaGarantia.css";

const SELECTOR_FOCUSABLES =
  'a[href], button:not([disabled]), textarea, input, select, [tabindex]:not([tabindex="-1"])';

export default function ModalNuevaGarantia({ onCerrar, onOrdenCreada }) {
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
        ? `Garantía ${respuesta.datos.numeroOrden} registrada correctamente.`
        : "La garantía se registró correctamente.",
    });
  }

  return (
    <div
      className="ng-superposicion"
      onMouseDown={(e) => e.target === e.currentTarget && vista === "formulario" && onCerrar()}
    >
      <div className="ng-caja" role="dialog" aria-modal="true" aria-labelledby="ng-titulo" ref={cajaRef}>
        <header className="ng-cabecera">
          <div>
            <p className="ng-cabecera-ruta">TALLER · NUEVA GARANTÍA</p>
            <h2 className="ng-cabecera-titulo" id="ng-titulo">
              {vista === "formulario" ? "Agregar nueva garantía" : "Comprobante de la garantía"}
            </h2>
          </div>
          {vista === "formulario" ? (
            <button type="button" className="ng-cerrar" aria-label="Cerrar" onClick={onCerrar}>
              <X size={18} strokeWidth={1.8} aria-hidden="true" />
            </button>
          ) : null}
        </header>

        <div className="ng-cuerpo">
          {vista === "formulario" ? (
            <>
              {errorEnvio ? (
                <p className="ng-error-envio" role="alert">
                  {errorEnvio}
                </p>
              ) : null}
              <FormularioGarantia onCrear={alCrear} onCancelar={onCerrar} enviando={enviando} />
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
