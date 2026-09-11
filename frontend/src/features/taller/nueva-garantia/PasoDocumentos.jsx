/**
 * Paso 3 del asistente: documentos de respaldo. Un paso propio (en vez de
 * ir dentro de "Cliente y equipo" como en el formulario original) porque
 * adjuntar es una decisión aparte y opcional -- no debe competir por
 * atención con los campos obligatorios del paso 1.
 */
import CampoDocumentos from "./CampoDocumentos.jsx";

export default function PasoDocumentos({ documentos, setDocumentos }) {
  return (
    <section className="ng-paso" aria-labelledby="ng-paso-3-titulo">
      <h3 className="ng-paso-titulo" id="ng-paso-3-titulo">
        Documentos
      </h3>
      <p className="ng-paso-ayuda">
        Adjunta la factura o fotos del equipo si las tienes a mano. Este paso es opcional -- puedes
        continuar sin subir nada y agregarlos después desde la ficha de la garantía.
      </p>
      <label className="ng-campo">
        <span className="ng-campo-etiqueta">Documentos</span>
        <CampoDocumentos pendientes={documentos} onCambiar={setDocumentos} />
      </label>
    </section>
  );
}
