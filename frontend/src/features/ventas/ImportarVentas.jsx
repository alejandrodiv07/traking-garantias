/**
 * Importación de facturas de Ventas (/ventas/importar, solo jefatura).
 * El CSV se lee en el navegador; solo viajan al servidor las filas válidas
 * (importar_ventas vuelve a validarlas). Al terminar se pueden descargar las
 * filas con error para corregirlas en Ventas.
 */
import { useState } from "react";
import { Link } from "react-router-dom";
import { aCsv, filasDeVentas } from "./csv.js";
import { importarVentas } from "./ventasService.js";
import "./ventas.css";

const MAX_BYTES = 10_000_000;
const MAX_VISTA = 100;

export default function ImportarVentas() {
  const [nombre, setNombre] = useState("");
  const [lectura, setLectura] = useState(null);
  const [aviso, setAviso] = useState(null);
  const [enviando, setEnviando] = useState(false);
  const [resultado, setResultado] = useState(null);

  async function elegir(ev) {
    const f = ev.target.files?.[0];
    setResultado(null);
    setLectura(null);
    setAviso(null);
    if (!f) return;
    if (f.size > MAX_BYTES) return setAviso("El archivo pesa más de 10 MB: divídelo en partes.");
    setNombre(f.name);
    const l = filasDeVentas(await f.text());
    if (l.faltantes.length) setAviso(`Faltan columnas obligatorias: ${l.faltantes.join(", ")}.`);
    else if (!l.filas.length) setAviso("El archivo no trae filas.");
    setLectura(l);
  }

  const filas = lectura?.filas ?? [];
  const cabecera = lectura?.cabecera ?? []; // el compilador de React lee esto al renderizar: nunca null
  const validas = filas.filter((f) => f.datos);
  const invalidas = filas.filter((f) => f.error);

  async function importar() {
    setEnviando(true);
    setAviso(null);
    const r = await importarVentas(nombre, validas.map((f) => f.datos));
    setEnviando(false);
    if (!r.ok) {
      const parcial = r.guardadas ? ` Se alcanzaron a guardar ${r.guardadas} filas: reimportar no duplica.` : "";
      return setAviso(`${r.mensaje || "No se pudo importar."}${parcial}`);
    }
    // Las filas que rechazó el servidor se suman a las de la vista previa.
    const delServidor = r.datos.errores.map((e) => ({
      ...validas[e.fila - 1],
      error: { campo: e.campo, mensaje: e.mensaje },
    }));
    setResultado({ ...r.datos, conError: [...invalidas, ...delServidor] });
  }

  function descargar(conError) {
    const csv = aCsv(
      [...cabecera, "error"],
      conError.map((f) => [...f.original, `${f.error.campo}: ${f.error.mensaje}`]),
    );
    const url = URL.createObjectURL(new Blob(["\uFEFF", csv], { type: "text/csv;charset=utf-8" }));
    const a = Object.assign(document.createElement("a"), { href: url, download: `errores-${nombre}` });
    a.click();
    URL.revokeObjectURL(url);
  }

  // Primero lo que hay que corregir; el resto, hasta MAX_VISTA filas.
  const vista = [...invalidas, ...validas].slice(0, MAX_VISTA);

  return (
    <section className="vi">
      <header className="enc">
        <h1>Importar ventas</h1>
        <Link to="/garantias" className="btn suave">
          Volver a Garantías
        </Link>
      </header>

      <p className="vi-ayuda" id="vi-ayuda">
        Columnas: numero_factura, fecha_emision (AAAA-MM-DD o DD/MM/AAAA), numero_documento, serial; opcionales:
        tipo_documento, nombre_cliente, modelo, vendedor. Separador «;» o «,». Reimportar el mismo archivo no duplica.
      </p>

      <label htmlFor="vi-archivo" className="vi-campo">
        Archivo CSV
        <input id="vi-archivo" type="file" accept=".csv,text/csv" onChange={elegir} aria-describedby="vi-ayuda" />
      </label>

      {aviso && <p role="alert" className="aviso-error">{aviso}</p>}

      {lectura && !lectura.faltantes.length && filas.length > 0 && (
        <>
          <p className="vi-conteo">
            {filas.length} filas · {validas.length} válidas · {invalidas.length} con error
          </p>

          <div className="vi-scroll" tabIndex={0} role="region" aria-label="Vista previa del archivo">
            <table className="vi-tabla">
              <thead>
                <tr>
                  <th scope="col">Fila</th>
                  <th scope="col">Factura</th>
                  <th scope="col">Fecha</th>
                  <th scope="col">Documento</th>
                  <th scope="col">Cliente</th>
                  <th scope="col">Serial</th>
                  <th scope="col">Estado</th>
                </tr>
              </thead>
              <tbody>
                {vista.map((f) => {
                  const d = f.crudo;
                  return (
                    <tr key={f.linea} data-error={f.error ? "" : undefined}>
                      <td>{f.linea}</td>
                      <td>{d.numero_factura}</td>
                      <td>{d.fecha_emision}</td>
                      <td>{d.numero_documento}</td>
                      <td>{d.nombre_cliente}</td>
                      <td className="cs-serial">{d.serial}</td>
                      <td>{f.error ? `Error: ${f.error.campo}, ${f.error.mensaje}` : "Válida"}</td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
          {filas.length > MAX_VISTA && (
            <p className="vi-ayuda">
              Se muestran {vista.length} de {filas.length} filas (primero las que tienen error).
            </p>
          )}
        </>
      )}

      {validas.length > 0 && !resultado && (
        <button type="button" className="btn principal vi-importar" disabled={enviando} onClick={importar}>
          {enviando ? "Importando…" : `Importar ${validas.length} filas válidas`}
        </button>
      )}

      {resultado && (
        <div role="status" className="vi-resumen">
          <p>
            Importación terminada: {resultado.nuevas} nuevas · {resultado.actualizadas} actualizadas ·{" "}
            {resultado.conError.length} con error · {resultado.confirmadas} garantías confirmadas.
          </p>
          {resultado.conError.length > 0 && (
            <button type="button" className="btn suave" onClick={() => descargar(resultado.conError)}>
              Descargar filas con error ({resultado.conError.length})
            </button>
          )}
        </div>
      )}
    </section>
  );
}
