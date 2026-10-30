// Paso 2 del asistente: el titular (spec §7.1). Búsqueda por cédula, RIF o
// pasaporte; si es nuevo, el tipo se infiere de la letra del documento.
import { useState } from "react";
import { buscarCliente, guardarCliente } from "../registroService.js";
import { normalizarDocumento } from "../normalizar.js";

const ESTA_VACIO = " ";

export default function PasoCliente({ estado, actualizar }) {
  const [modo, setModo] = useState(estado?.clienteId ? "existente" : "nuevo");
  const [tipo, setTipo] = useState(estado?.tipo ?? "");
  const [documento, setDocumento] = useState(estado?.documento ?? "");
  const [nombre, setNombre] = useState(estado?.nombre ?? "");
  const [telefono, setTelefono] = useState(estado?.telefono ?? "");
  const [error, setError] = useState("");

  async function alEscribirDocumento(e) {
    const { tipo: t, documento: d } = normalizarDocumento(e.target.value);
    setDocumento(d);
    setError(d.length < 5 && d.length > 0 ? "El documento necesita al menos 5 dígitos" : "");
    // Teclear un documento nuevo invalida el titular hallado antes: si no se
    // limpia, el registro se crearía con el clienteId del documento ANTERIOR.
    if (t) {
      setTipo(t);
      actualizar({ tipo: t, documento: d, clienteId: null, clienteNombre: null });
    } else {
      actualizar({ documento: d, clienteId: null, clienteNombre: null });
    }
    // Si ya existe, el titular se trae de la base.
    if (d.length >= 5) {
      const r = await buscarCliente(d);
      if (r.ok && r.datos) {
        setModo("existente");
        setTipo(r.datos.tipo_documento ?? "");
        setNombre(r.datos.nombre ?? "");
        setTelefono(r.datos.telefono ?? "");
        setError("");
        actualizar({
          clienteId: r.datos.id,
          clienteNombre: r.datos.nombre,
          tipo: r.datos.tipo_documento ?? "",
          documento: d,
        });
      }
    }
  }

  async function guardar() {
    setError("");
    if (documento.length < 5) {
      setError("El documento necesita al menos 5 dígitos");
      return;
    }
    const r = await guardarCliente({
      tipo: tipo || null,
      documento,
      nombre,
      telefono: telefono || null,
    });
    if (r.ok) {
      actualizar({ clienteId: r.datos, clienteNombre: nombre, tipo, documento });
    } else {
      setError(r.mensaje ?? "No se pudo guardar el titular");
    }
  }

  return (
    <div>
      <div role="group" aria-label="Modo del titular">
        <button type="button" onClick={() => setModo("nuevo")}>
          Nuevo
        </button>
        <button type="button" onClick={() => setModo("existente")}>
          Existente
        </button>
      </div>

      <label htmlFor="documento">
        Documento (cédula, RIF o pasaporte)
        <input
          id="documento"
          value={documento}
          onChange={alEscribirDocumento}
          autoComplete="off"
        />
      </label>
      {error && (
        <p role="alert" aria-describedby="documento">
          {error}
        </p>
      )}

      {modo === "nuevo" && (
        <>
          <label htmlFor="tipo">
            Tipo
            <select id="tipo" value={tipo} onChange={(e) => setTipo(e.target.value)}>
              <option value="">—</option>
              <option value="V">V (cédula)</option>
              <option value="E">E (extranjero)</option>
              <option value="J">J (RIF jurídico)</option>
              <option value="G">G (RIF gubernamental)</option>
              <option value="P">P (pasaporte)</option>
            </select>
          </label>
          <label htmlFor="nombre">
            Nombre
            <input id="nombre" value={nombre} onChange={(e) => setNombre(e.target.value)} />
          </label>
          <label htmlFor="telefono">
            Teléfono
            <input id="telefono" value={telefono} onChange={(e) => setTelefono(e.target.value)} />
          </label>
          <button type="button" onClick={guardar}>
            Usar este titular
          </button>
        </>
      )}

      {modo === "existente" && nombre !== ESTA_VACIO && nombre && (
        <p>Titular: {nombre}</p>
      )}
    </div>
  );
}