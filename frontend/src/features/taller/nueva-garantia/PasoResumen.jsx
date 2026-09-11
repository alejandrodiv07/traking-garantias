/**
 * Paso 4, último: revisión de solo lectura antes de enviar. No repite
 * validación -- si se llegó hasta aquí es porque los tres pasos previos ya
 * pasaron la suya -- solo le da al mostrador una última mirada a lo que
 * está por registrarse, con la etiqueta legible de cada opción en vez del
 * código interno (nadie en el mostrador piensa en "EXTENDIDA").
 */
import { useTecnicos } from "../datos/hooks.js";

const ETIQUETA_TIPO_GARANTIA = {
  ESTANDAR: "Estándar de fábrica",
  EXTENDIDA: "Extendida",
  SIN_GARANTIA: "Sin garantía",
};

const ETIQUETA_PRIORIDAD = {
  BAJA: "Baja",
  NORMAL: "Normal",
  ALTA: "Alta",
  URGENTE: "Urgente",
};

function Fila({ etiqueta, valor }) {
  return (
    <div className="ng-resumen-fila">
      <span className="ng-resumen-etiqueta">{etiqueta}</span>
      <span className="ng-resumen-valor">{valor || "—"}</span>
    </div>
  );
}

export default function PasoResumen({
  cliente,
  producto,
  numeroSerie,
  numeroFactura,
  accesorios,
  fallaReportada,
  fechaCompra,
  tipoGarantia,
  mesesOverride,
  prioridad,
  tecnicoId,
  slaDias,
  documentos,
}) {
  const { tecnicos } = useTecnicos();
  const nombreCliente = cliente?.existente?.nombre ?? cliente?.nuevo?.nombre ?? "";
  const nombreProducto = producto?.existente?.modelo ?? producto?.nuevo?.modelo ?? "";
  const nombreTecnico = tecnicos.find((t) => t.id === tecnicoId)?.full_name;

  return (
    <section className="ng-paso" aria-labelledby="ng-paso-4-titulo">
      <h3 className="ng-paso-titulo" id="ng-paso-4-titulo">
        Revisa antes de registrar
      </h3>

      <h4 className="ng-resumen-grupo-titulo">Cliente y equipo</h4>
      <div className="ng-resumen-grupo">
        <Fila etiqueta="Cliente" valor={nombreCliente} />
        <Fila etiqueta="Equipo" valor={nombreProducto} />
        <Fila etiqueta="Nº de serie" valor={numeroSerie} />
        <Fila etiqueta="Nº de factura" valor={numeroFactura} />
        <Fila etiqueta="Accesorios" valor={accesorios} />
      </div>
      <p className="ng-resumen-falla">{fallaReportada}</p>

      <h4 className="ng-resumen-grupo-titulo">Cobertura</h4>
      <div className="ng-resumen-grupo">
        <Fila
          etiqueta="Fecha de compra"
          valor={fechaCompra ? new Date(fechaCompra + "T00:00:00").toLocaleDateString("es-VE") : ""}
        />
        <Fila etiqueta="Tipo de garantía" valor={ETIQUETA_TIPO_GARANTIA[tipoGarantia]} />
        {tipoGarantia === "EXTENDIDA" ? <Fila etiqueta="Duración" valor={`${mesesOverride} meses`} /> : null}
      </div>

      <h4 className="ng-resumen-grupo-titulo">Prioridad y asignación</h4>
      <div className="ng-resumen-grupo">
        <Fila etiqueta="Prioridad" valor={ETIQUETA_PRIORIDAD[prioridad]} />
        <Fila etiqueta="Técnico" valor={nombreTecnico ?? "Sin asignar"} />
        <Fila etiqueta="Plazo de entrega" valor={`${slaDias} días`} />
      </div>

      <h4 className="ng-resumen-grupo-titulo">Documentos</h4>
      <div className="ng-resumen-grupo">
        <Fila
          etiqueta="Adjuntos"
          valor={
            documentos.length === 0
              ? "Ninguno"
              : `${documentos.length} ${documentos.length === 1 ? "archivo" : "archivos"}`
          }
        />
      </div>
    </section>
  );
}
