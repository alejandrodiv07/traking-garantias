/**
 * Consulta de garantía — pantalla de mostrador de "Ventas y garantías".
 *
 * Busca un equipo por serial, cédula/RIF, nº de factura o nº de orden y
 * muestra todo lo que se registró al darlo de alta en "Nueva orden": el
 * equipo y su período de cobertura, los documentos adjuntos, el historial
 * de órdenes de servicio abiertas sobre ese equipo, y los datos del
 * cliente para poder llamarlo o reimprimir su factura.
 *
 * Reutiliza el mismo lenguaje visual que `Tablero.jsx` (`.tg-*`, definido en
 * `Tablero.css`) para que las dos pantallas del taller se vean como una
 * sola aplicación -- no una paleta nueva por pantalla.
 *
 * La búsqueda en sí es de DEMOSTRACIÓN (`datos/consultaGarantia.js` explica
 * por qué: falta una RPC que todavía no existe). El resto de la pantalla
 * -- estados de carga, error, "sin resultado", descarga de documentos,
 * acciones -- está construido para el dato real, no para la maqueta.
 */
import { useState } from "react";
import { useNavigate } from "react-router-dom";
import {
  Bell,
  Boxes,
  Download,
  FileText,
  LogOut,
  Mail,
  Phone,
  PackageSearch,
  Printer,
  Search,
  Send,
  ShieldCheck,
  User,
} from "lucide-react";
import { useAuth } from "../auth/AuthContext.jsx";
import BarraLateral from "../taller/componentes/BarraLateral.jsx";
import { cobertura as coberturaDe, diasHasta, fechaCorta, tonoDeEstado } from "../taller/dominio.js";
import { buscarGarantia } from "./datos/consultaGarantia.js";
import "../taller/Tablero.css";
import "./ConsultaGarantia.css";

/** "María Pérez" -> "MP"; un solo nombre -> sus dos primeras letras. Igual
    que `Tablero.jsx`: mismo criterio de iniciales en toda la app. */
function iniciales(nombre) {
  const partes = String(nombre ?? "").trim().split(/\s+/).filter(Boolean);
  if (partes.length === 0) return "··";
  if (partes.length === 1) return partes[0].slice(0, 2).toUpperCase();
  return (partes[0][0] + partes[partes.length - 1][0]).toUpperCase();
}

function fechaLarga(iso) {
  return new Date(`${iso}T00:00:00`).toLocaleDateString("es-VE", {
    day: "numeric",
    month: "short",
    year: "numeric",
  });
}

export default function ConsultaGarantia() {
  const { perfil, rol, salir } = useAuth();
  const navigate = useNavigate();

  const usuario = {
    nombre: perfil?.full_name ?? "",
    iniciales: iniciales(perfil?.full_name),
    rol: rol ?? "",
  };

  const [criterio, setCriterio] = useState("");
  const [estado, setEstado] = useState("inicial"); // inicial | buscando | encontrada | sin_resultado | error
  const [garantia, setGarantia] = useState(null);
  const [aviso, setAviso] = useState(null);

  function avisar(texto) {
    setAviso({ texto, en: Date.now() });
    setTimeout(() => setAviso(null), 3500);
  }

  async function alBuscar(evento) {
    evento.preventDefault();
    const valor = criterio.trim();
    if (!valor) return;

    setEstado("buscando");
    try {
      const resultado = await buscarGarantia(valor);
      if (resultado) {
        setGarantia(resultado);
        setEstado("encontrada");
      } else {
        setGarantia(null);
        setEstado("sin_resultado");
      }
    } catch {
      setEstado("error");
    }
  }

  function onIr(clave, etiqueta) {
    if (clave === "tablero") return navigate("/admin");
    if (clave === "garantias") return; // ya estamos aquí
    avisar(`«${etiqueta}» todavía no está construida.`);
  }

  function descargar(documento) {
    // Documentos de demostración (ver datos/garantiasDemo.js): no hay un
    // objeto real en Storage que firmar. Cuando la búsqueda venga de la
    // RPC real, este handler pasa a llamar `rutaFirmada()`
    // (`taller/datos/documentos.js`), que ya existe y ya funciona.
    avisar(`Descarga de «${documento.nombreArchivo}» simulada (dato de demostración).`);
  }

  return (
    <div className="tg">
      <BarraLateral actual="garantias" usuario={usuario} onIr={onIr} />

      <div className="tg-main">
        <header className="tg-topbar">
          <p className="tg-ruta">
            Ventas y garantías / <strong>Consulta</strong>
          </p>
          <div className="tg-topbar-acciones">
            <button
              type="button"
              className="tg-btn tg-btn--suave tg-btn--icono"
              aria-label="Notificaciones"
              onClick={() => avisar("El centro de notificaciones todavía no está construido.")}
            >
              <Bell size={18} strokeWidth={1.8} aria-hidden="true" />
            </button>
            <button type="button" className="tg-btn tg-btn--suave" onClick={salir}>
              <LogOut size={16} strokeWidth={1.8} aria-hidden="true" />
              Cerrar sesión
            </button>
            <span className="tg-avatar" title={`${usuario.nombre} · ${usuario.rol}`}>
              <span aria-hidden="true">{usuario.iniciales}</span>
              <span className="tg-sr">
                Sesión de {usuario.nombre}, {usuario.rol}
              </span>
            </span>
          </div>
        </header>

        <main className="tg-contenido">
          <div className="tg-encabezado">
            <div>
              <h1 className="tg-titulo">Consulta de garantía</h1>
              <p className="tg-subtitulo">
                Localiza un equipo por serial, cédula/RIF, nº de factura o nº de orden.
              </p>
            </div>
          </div>

          <form className="cg-buscador" onSubmit={alBuscar} role="search">
            <label className="tg-sr" htmlFor="cg-criterio">
              Serial, cédula/RIF, nº de factura o nº de orden
            </label>
            <div className="cg-buscador-campo">
              <Search size={18} strokeWidth={1.8} className="cg-buscador-icono" aria-hidden="true" />
              <input
                id="cg-criterio"
                className="tg-input tg-mono cg-buscador-input"
                placeholder="Ej. RT5-8842-AA, J-30589214-7, V-0012, OS-2026-0142…"
                value={criterio}
                onChange={(e) => setCriterio(e.target.value)}
                autoComplete="off"
                disabled={estado === "buscando"}
              />
            </div>
            <button type="submit" className="tg-btn tg-btn--principal cg-buscador-boton" disabled={estado === "buscando"}>
              {estado === "buscando" ? "Buscando…" : "Buscar"}
            </button>
          </form>

          <p className="tg-sr" role="status" aria-live="polite">
            {estado === "buscando"
              ? "Buscando…"
              : estado === "encontrada"
                ? `Equipo encontrado: ${garantia.equipo.nombre}`
                : estado === "sin_resultado"
                  ? "Ningún equipo coincide con ese criterio."
                  : null}
          </p>

          {estado === "inicial" ? (
            <div className="tg-card cg-vacio">
              <Search size={30} strokeWidth={1.5} aria-hidden="true" />
              <p className="tg-vacio-titulo">Escribe un criterio para empezar</p>
              <p className="tg-vacio-texto">
                El resultado muestra el equipo, su cobertura, los documentos adjuntos y las
                órdenes de servicio registradas.
              </p>
            </div>
          ) : null}

          {estado === "error" ? (
            <div className="tg-card tg-vacio" role="alert">
              <p className="tg-vacio-titulo">No se pudo completar la búsqueda</p>
              <p className="tg-vacio-texto">Intenta de nuevo en unos segundos.</p>
            </div>
          ) : null}

          {estado === "sin_resultado" ? (
            <div className="tg-card cg-vacio">
              <PackageSearch size={30} strokeWidth={1.5} aria-hidden="true" />
              <p className="tg-vacio-titulo">Ningún equipo coincide con «{criterio}»</p>
              <p className="tg-vacio-texto">
                Revisa el serial, la cédula/RIF, el nº de factura o el nº de orden e intenta de
                nuevo.
              </p>
            </div>
          ) : null}

          {estado === "encontrada" ? <Resultado garantia={garantia} onDescargar={descargar} onAvisar={avisar} /> : null}
        </main>
      </div>

      {aviso ? (
        <p className="tg-aviso" role="status" aria-live="polite">
          {aviso.texto}
        </p>
      ) : null}
    </div>
  );
}

function Resultado({ garantia, onDescargar, onAvisar }) {
  const { equipo, cliente, documentos, ordenes } = garantia;
  const cob = coberturaDe(equipo.cobertura);

  const diasRestantes = diasHasta(equipo.finCobertura);
  const diasTotales = Math.max(diasHasta(equipo.finCobertura, new Date(`${equipo.fechaCompra}T00:00:00`)), 1);
  const progreso = Math.min(Math.max(1 - diasRestantes / diasTotales, 0), 1);
  const vigente = equipo.cobertura === "EN_GARANTIA";

  return (
    <div className="tg-cuerpo cg-cuerpo">
      <div className="cg-columna-principal">
        {/* Equipo + cobertura */}
        <div className="tg-card cg-equipo">
          <div className="cg-equipo-fila">
            <div className="cg-equipo-icono" aria-hidden="true">
              <Boxes size={30} strokeWidth={1.6} />
            </div>
            <div className="cg-equipo-info">
              <p className="cg-equipo-nombre">{equipo.nombre}</p>
              <p className="cg-equipo-marca">
                {equipo.marca} · {equipo.categoria}
              </p>
              <div className="cg-equipo-meta">
                <div>
                  <p className="cg-equipo-meta-etiqueta">Serial</p>
                  <p className="tg-mono cg-equipo-meta-valor">{equipo.serial}</p>
                </div>
                <div>
                  <p className="cg-equipo-meta-etiqueta">Factura</p>
                  <p className="tg-mono cg-equipo-meta-valor">{equipo.numeroFactura}</p>
                </div>
                <div>
                  <p className="cg-equipo-meta-etiqueta">Comprado</p>
                  <p className="cg-equipo-meta-valor">{fechaLarga(equipo.fechaCompra)}</p>
                </div>
              </div>
            </div>
            <span className="tg-insignia cg-insignia-cobertura" data-tono={cob.tono}>
              <ShieldCheck size={13} strokeWidth={2.2} aria-hidden="true" />
              {cob.nombre}
            </span>
          </div>

          <div className="cg-cobertura">
            <div className="cg-cobertura-cabecera">
              <span className="cg-cobertura-titulo">Período de cobertura</span>
              <span className="cg-cobertura-restante" data-tono={cob.tono}>
                {vigente
                  ? diasRestantes >= 0
                    ? `${diasRestantes} ${diasRestantes === 1 ? "día restante" : "días restantes"}`
                    : `Venció hace ${Math.abs(diasRestantes)} d`
                  : "Sin cobertura vigente"}
              </span>
            </div>
            <div className="cg-cobertura-fechas">
              <span>Inicio · {fechaLarga(equipo.fechaCompra)}</span>
              <span>Fin · {fechaLarga(equipo.finCobertura)}</span>
            </div>
            <div className="cg-cobertura-barra">
              <div
                className="cg-cobertura-barra-relleno"
                data-tono={cob.tono}
                style={{ width: `${Math.round(progreso * 100)}%` }}
              />
            </div>
          </div>
        </div>

        {/* Documentos */}
        <div className="tg-card cg-tarjeta">
          <div className="cg-tarjeta-cabecera">
            <span className="cg-tarjeta-titulo">Documentos vinculados</span>
            <span className="cg-tarjeta-nota">Descarga con JWT + rol</span>
          </div>
          {documentos.length > 0 ? (
            <div className="cg-documentos">
              {documentos.map((doc) => (
                <button
                  key={doc.id}
                  type="button"
                  className="cg-documento"
                  onClick={() => onDescargar(doc)}
                >
                  <span className="cg-documento-icono" aria-hidden="true">
                    <FileText size={18} strokeWidth={1.9} />
                  </span>
                  <span className="cg-documento-info">
                    <span className="cg-documento-nombre">{doc.nombreArchivo}</span>
                    <span className="cg-documento-etiqueta">{doc.etiqueta}</span>
                  </span>
                  <Download size={16} strokeWidth={2} className="cg-documento-descarga" aria-hidden="true" />
                </button>
              ))}
            </div>
          ) : (
            <p className="cg-tarjeta-sub-vacia">Sin documentos adjuntos.</p>
          )}
        </div>

        {/* Órdenes de servicio */}
        <div className="tg-card cg-tarjeta">
          <span className="cg-tarjeta-titulo">Órdenes de servicio del equipo</span>
          {ordenes.length > 0 ? (
            <ul className="cg-ordenes">
              {ordenes.map((orden) => {
                const tono = tonoDeEstado(orden.estado);
                return (
                  <li key={orden.numero} className="cg-orden">
                    <span className="tg-mono cg-orden-numero">{orden.numero}</span>
                    <span className="cg-orden-falla">{orden.falla}</span>
                    <span className="tg-insignia cg-orden-estado" data-tono={tono}>
                      <span className="tg-insignia-punto" aria-hidden="true" />
                      {ESTADOS_NOMBRE[orden.estado] ?? orden.estado}
                    </span>
                    <span className="cg-orden-fecha">{fechaCorta(orden.fecha)}</span>
                  </li>
                );
              })}
            </ul>
          ) : (
            <p className="cg-tarjeta-sub-vacia">Este equipo no tiene órdenes de servicio registradas.</p>
          )}
        </div>
      </div>

      <aside className="cg-columna-lateral">
        <div className="tg-card cg-tarjeta">
          <span className="cg-tarjeta-titulo">Cliente</span>
          <div className="cg-cliente-cabecera">
            <span className="tg-avatar cg-cliente-avatar" aria-hidden="true">
              {iniciales(cliente.nombre)}
            </span>
            <div>
              <p className="cg-cliente-nombre">{cliente.nombre}</p>
              <p className="tg-mono cg-cliente-documento">{cliente.documento}</p>
            </div>
          </div>
          <div className="cg-cliente-datos">
            <span>
              <User size={15} strokeWidth={1.8} aria-hidden="true" />
              {cliente.contacto}
            </span>
            <span>
              <Mail size={15} strokeWidth={1.8} aria-hidden="true" />
              {cliente.email}
            </span>
            <span>
              <Phone size={15} strokeWidth={1.8} aria-hidden="true" />
              {cliente.telefono}
            </span>
          </div>
        </div>

        <div className="tg-card cg-tarjeta">
          <span className="cg-tarjeta-titulo">Acciones</span>
          <div className="cg-acciones">
            <button
              type="button"
              className="tg-btn tg-btn--principal tg-btn--ancho"
              onClick={() => onAvisar("«Abrir orden de servicio» todavía no está construida.")}
            >
              Abrir orden de servicio
            </button>
            <button
              type="button"
              className="tg-btn tg-btn--suave tg-btn--ancho"
              onClick={() => onAvisar("«Imprimir factura» todavía no está construida.")}
            >
              <Printer size={16} strokeWidth={1.8} aria-hidden="true" />
              Imprimir factura
            </button>
            <button
              type="button"
              className="tg-btn tg-btn--suave tg-btn--ancho"
              onClick={() => onAvisar("«Enviar enlace de seguimiento» todavía no está construida.")}
            >
              <Send size={16} strokeWidth={1.8} aria-hidden="true" />
              Enviar enlace de seguimiento
            </button>
          </div>
        </div>
      </aside>
    </div>
  );
}

/** Nombres legibles de los códigos de `estados_garantia` que aparecen en la
    demo. El catálogo real se consulta con `listarEstados()`
    (`taller/datos/catalogos.js`); esto es solo el rótulo de exhibición
    mientras la búsqueda es de demostración. */
const ESTADOS_NOMBRE = {
  RECIBIDO: "Recibido",
  EN_DIAGNOSTICO: "En diagnóstico",
  PRESUPUESTADO: "Presupuestado",
  EN_ESPERA_REPUESTO: "En espera de repuesto",
  EN_REPARACION: "En reparación",
  REPARADO: "Reparado",
  IRREPARABLE: "Irreparable",
  RECHAZADO_POR_CLIENTE: "Rechazado por cliente",
  ENTREGADO: "Entregado",
  ANULADO: "Anulado",
};
