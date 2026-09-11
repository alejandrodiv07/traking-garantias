/**
 * Cliente: busca uno existente, o compone el JSONB de un cliente nuevo.
 *
 * Emite hacia `FormularioGarantia` un valor con esta forma:
 *   { id, existente, _valido: true }                        -- cliente existente
 *   { nuevo: {...}, existente: {...}, _valido: boolean }     -- cliente nuevo
 *
 * `_valido` es lo que permite al asistente bloquear "Siguiente" en el paso 1
 * sin duplicar aquí la regla de validación: cada campo nuevo se valida en
 * el propio `onBlur` (ui-ux-pro-max `inline-validation`: al salir del campo,
 * no en cada tecla) y el resultado combinado decide `_valido`.
 *
 * Es exactamente lo que `crear_orden()` espera en `p_cliente_id` /
 * `p_cliente_nuevo` (ADR-009): nada se inserta aquí, los datos solo se
 * acumulan hasta que la garantía se crea de verdad.
 */
import { useState } from "react";
import { errorDocumento, errorEmail, errorNombre, errorTelefono, AYUDA } from "./validacion.js";
import { useBusquedaClientes } from "../datos/hooks.js";
import SelectorAsincrono from "./SelectorAsincrono.jsx";

const TIPOS_DOCUMENTO = ["V", "E", "J", "G", "P"];

function etiquetaCliente(c) {
  return c.nombre;
}
function detalleCliente(c) {
  return `${c.tipo_documento}-${c.documento}`;
}

export default function CampoCliente({ valor, onCambiar, errores }) {
  const { termino, setTermino, clientes, buscando } = useBusquedaClientes();
  const [registrandoNuevo, setRegistrandoNuevo] = useState(false);
  const [nuevo, setNuevo] = useState({
    tipo_documento: "V",
    documento: "",
    nombre: "",
    telefono: "",
    email: "",
  });
  const [tocado, setTocado] = useState({});

  // OJO: `valor.existente` también viaja en el borrador de un cliente
  // NUEVO (línea 66 más abajo, para que el resumen tenga con qué pintar un
  // nombre) y ese objeto es truthy desde la primera tecla. Si `seleccionado`
  // se leyera de ahí, tipear cualquier campo del alta lo disparaba a
  // verdadero y el `if` de abajo abandonaba el formulario de dos campos a
  // mitad de escritura -- el campo no se "bloqueaba", el formulario entero
  // desaparecía debajo del cursor. Solo un `id` real (una fila ya elegida
  // por búsqueda) cuenta como "seleccionado".
  const seleccionado = valor?.id ? valor.existente : null;

  function seleccionarExistente(cliente) {
    onCambiar({ id: cliente.id, existente: cliente, _valido: true });
  }

  function limpiarSeleccion() {
    onCambiar(null);
    setRegistrandoNuevo(false);
    setTermino("");
    setTocado({});
  }

  function empezarRegistroNuevo() {
    setRegistrandoNuevo(true);
    // El nombre tecleado en la búsqueda es casi siempre el nombre real:
    // se precarga para no hacer escribirlo dos veces.
    setNuevo((n) => ({ ...n, nombre: termino }));
  }

  function actualizarNuevo(campo, valorCampo) {
    const siguiente = { ...nuevo, [campo]: valorCampo };
    setNuevo(siguiente);

    const documentoLimpio = siguiente.documento.replace(/\D/g, "");
    const valido =
      !errorNombre(siguiente.nombre) &&
      !errorDocumento(documentoLimpio) &&
      !errorTelefono(siguiente.telefono) &&
      !errorEmail(siguiente.email);

    onCambiar({
      nuevo: {
        tipo_documento: siguiente.tipo_documento,
        documento: documentoLimpio,
        nombre: siguiente.nombre.trim(),
        telefono: siguiente.telefono.trim() || undefined,
        email: siguiente.email.trim() ? siguiente.email.trim().toLowerCase() : undefined,
      },
      existente: {
        nombre: siguiente.nombre,
        tipo_documento: siguiente.tipo_documento,
        documento: documentoLimpio,
      },
      _valido: valido,
    });
  }

  function marcarTocado(campo) {
    setTocado((t) => ({ ...t, [campo]: true }));
  }

  if (registrandoNuevo && !seleccionado) {
    const errNombre = tocado.nombre ? errorNombre(nuevo.nombre) : null;
    const errDocumento = tocado.documento ? errorDocumento(nuevo.documento) : null;
    const errTelefono = tocado.telefono ? errorTelefono(nuevo.telefono) : null;
    const errEmail = tocado.email ? errorEmail(nuevo.email) : null;

    return (
      <div className="ng-cliente-nuevo">
        {/* El nombre va solo en su fila: recortarlo a la mitad del ancho
            junto a la cédula lo hacía ilegible con razones sociales largas. */}
        <label className="ng-campo">
          <span className="ng-campo-etiqueta">Cliente *</span>
          <input
            className="tg-input"
            value={nuevo.nombre}
            onChange={(e) => actualizarNuevo("nombre", e.target.value)}
            onBlur={() => marcarTocado("nombre")}
            placeholder="Nombre o razón social"
            maxLength={160}
            required
            aria-invalid={errNombre ? "true" : undefined}
            aria-describedby="ng-cliente-nombre-ayuda"
          />
          <span id="ng-cliente-nombre-ayuda" className="ng-campo-ayuda">
            {AYUDA.nombre} (3 a 160 caracteres)
          </span>
          {errNombre ? <p className="ng-campo-error">{errNombre}</p> : null}
        </label>
        <div className="ng-grid-2">
          <label className="ng-campo">
            <span className="ng-campo-etiqueta">Cédula / RIF *</span>
            <div className="ng-documento">
              <select
                className="tg-input ng-documento-tipo"
                value={nuevo.tipo_documento}
                onChange={(e) => actualizarNuevo("tipo_documento", e.target.value)}
                aria-label="Tipo de documento"
              >
                {TIPOS_DOCUMENTO.map((t) => (
                  <option key={t} value={t}>
                    {t}
                  </option>
                ))}
              </select>
              <input
                className="tg-input"
                inputMode="numeric"
                value={nuevo.documento}
                onChange={(e) => actualizarNuevo("documento", e.target.value.replace(/\D/g, ""))}
                onBlur={() => marcarTocado("documento")}
                placeholder="12345678"
                maxLength={15}
                required
                aria-invalid={errDocumento ? "true" : undefined}
                aria-describedby="ng-cliente-documento-ayuda"
              />
            </div>
            <span id="ng-cliente-documento-ayuda" className="ng-campo-ayuda">
              {AYUDA.documento}
            </span>
            {errDocumento ? <p className="ng-campo-error">{errDocumento}</p> : null}
          </label>
          <label className="ng-campo">
            <span className="ng-campo-etiqueta">Teléfono</span>
            <input
              className="tg-input"
              type="tel"
              inputMode="tel"
              value={nuevo.telefono}
              onChange={(e) => actualizarNuevo("telefono", e.target.value)}
              onBlur={() => marcarTocado("telefono")}
              placeholder="04141234567"
              maxLength={20}
              aria-invalid={errTelefono ? "true" : undefined}
              aria-describedby="ng-cliente-telefono-ayuda"
            />
            <span id="ng-cliente-telefono-ayuda" className="ng-campo-ayuda">
              {AYUDA.telefono} Para enviarle recordatorios.
            </span>
            {errTelefono ? <p className="ng-campo-error">{errTelefono}</p> : null}
          </label>
        </div>
        <label className="ng-campo">
          <span className="ng-campo-etiqueta">Correo</span>
          <input
            className="tg-input"
            type="email"
            inputMode="email"
            value={nuevo.email}
            onChange={(e) => actualizarNuevo("email", e.target.value)}
            onBlur={() => marcarTocado("email")}
            placeholder="cliente@correo.com"
            maxLength={160}
            aria-invalid={errEmail ? "true" : undefined}
            aria-describedby="ng-cliente-email-ayuda"
          />
          <span id="ng-cliente-email-ayuda" className="ng-campo-ayuda">
            {AYUDA.email} Para el comprobante y avisos, opcional.
          </span>
          {errEmail ? <p className="ng-campo-error">{errEmail}</p> : null}
        </label>
        {errores?.cliente ? <p className="ng-campo-error">{errores.cliente}</p> : null}
        <button type="button" className="tg-enlace" onClick={limpiarSeleccion}>
          Buscar un cliente existente en su lugar
        </button>
      </div>
    );
  }

  return (
    <label className="ng-campo">
      <span className="ng-campo-etiqueta">Cliente *</span>
      <SelectorAsincrono
        placeholder="Nombre o cédula/RIF…"
        termino={termino}
        onTerminoCambia={setTermino}
        resultados={clientes}
        buscando={buscando}
        etiquetaDe={etiquetaCliente}
        detalleDe={detalleCliente}
        seleccionado={seleccionado}
        onSeleccionar={seleccionarExistente}
        onLimpiarSeleccion={limpiarSeleccion}
        onRegistrarNuevo={empezarRegistroNuevo}
        etiquetaRegistrarNuevo={`Registrar «${termino}» como cliente nuevo`}
        requerido
        error={errores?.cliente}
      />
    </label>
  );
}
