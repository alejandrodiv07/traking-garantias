/**
 * Tabla de órdenes.
 *
 * Es un `<table>` de verdad, no una rejilla de `<div>`: la relación entre una
 * celda y su cabecera es lo que permite a un lector de pantalla anunciar
 * "Estado: En diagnóstico" en vez de leer una tira de textos sueltos. En móvil
 * la hoja de estilos lo convierte visualmente en fichas, pero el marcado —y
 * por tanto la semántica— no cambia; las cabeceras las repone `data-etiqueta`.
 *
 * El componente no filtra ni ordena: recibe las filas ya resueltas. Cuando los
 * datos vengan de Supabase el filtrado se hará en la consulta (hay índices
 * parciales para eso), no en el navegador.
 */
import { PackageOpen } from "lucide-react";
import { cobertura as coberturaDe, tonoDeEstado, fechaCorta } from "../dominio.js";

const COLUMNAS = [
  "Nº de orden",
  "Cliente",
  "Equipo",
  "Cobertura",
  "Estado",
  "Ingresó",
];

export default function TablaOrdenes({ ordenes, total, hayFiltro, onLimpiar, onVerTodas }) {
  return (
    <div className="tg-card tg-tabla-caja">
      <div className="tg-scroll">
        <table className="tg-tabla">
          <caption className="tg-sr">
            Órdenes de servicio del taller. {ordenes.length} de {total} órdenes.
          </caption>
          <thead>
            <tr>
              {COLUMNAS.map((c) => (
                <th key={c} scope="col">
                  {c}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {ordenes.map((o) => {
              const tonoEstado = tonoDeEstado(o.estado);
              const cob = coberturaDe(o.cobertura);
              return (
                <tr key={o.id}>
                  <td data-etiqueta="Nº de orden">
                    <span className="tg-numero-orden tg-mono">{o.numero}</span>
                  </td>
                  <td data-etiqueta="Cliente">
                    <div>
                      <div className="tg-celda-principal" title={o.cliente}>
                        {o.cliente}
                      </div>
                      <div className="tg-celda-secundaria tg-mono">{o.documento}</div>
                    </div>
                  </td>
                  <td data-etiqueta="Equipo">
                    <div>
                      <div className="tg-celda-principal" title={o.equipo}>
                        {o.equipo}
                      </div>
                      <div className="tg-celda-secundaria tg-mono">
                        {o.serie ?? "Sin número de serie"}
                      </div>
                    </div>
                  </td>
                  <td data-etiqueta="Cobertura">
                    <span
                      className="tg-insignia tg-insignia--cuadrada"
                      data-tono={cob.tono}
                    >
                      {cob.nombre}
                    </span>
                  </td>
                  <td data-etiqueta="Estado">
                    <span className="tg-insignia" data-tono={tonoEstado}>
                      <span className="tg-insignia-punto" aria-hidden="true" />
                      {o.estadoNombre}
                    </span>
                  </td>
                  <td data-etiqueta="Ingresó" className="tg-col-fecha">
                    <time dateTime={o.ingreso}>{fechaCorta(o.ingreso)}</time>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>

      {ordenes.length === 0 ? (
        <div className="tg-vacio">
          <PackageOpen size={32} strokeWidth={1.5} aria-hidden="true" />
          <p className="tg-vacio-titulo">Ninguna orden coincide</p>
          <p className="tg-vacio-texto">
            Prueba con otro término, o quita el filtro para ver las {total} órdenes.
          </p>
          {hayFiltro ? (
            <button type="button" className="tg-btn tg-btn--suave" onClick={onLimpiar}>
              Quitar filtros
            </button>
          ) : null}
        </div>
      ) : (
        <div className="tg-tabla-pie">
          <span>
            Mostrando {ordenes.length} de {total} órdenes
          </span>
          <button type="button" className="tg-enlace" onClick={onVerTodas}>
            Ver todas →
          </button>
        </div>
      )}
    </div>
  );
}
