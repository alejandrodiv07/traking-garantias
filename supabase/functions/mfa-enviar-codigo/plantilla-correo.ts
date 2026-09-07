// =====================================================================
//  Plantilla del correo de verificación (2FA)
//  Prime Telecom · Track Garantía
//
//  Tabla, no flexbox/grid: es el único layout que Outlook, Gmail y Apple
//  Mail renderizan igual. Estilos EN LÍNEA y no en un <style>: la mayoría
//  de los clientes de correo eliminan la etiqueta <style> del <head>, y un
//  código que llega sin subrayado ni color no es un problema estético, es
//  un código que el usuario no encuentra en la pantalla.
//
//  Paleta y tipografía: los mismos tokens que `login.css` (--pt-*), para que
//  el correo se sienta parte del mismo producto que la pantalla que lo pidió
//  y no una plantilla de outro sistema. `Georgia`/`Menlo` como pila de
//  respaldo del código: es la única familia monoespaciada que Outlook para
//  Windows (que renderiza con el motor de Word, no un navegador) reconoce
//  sin sustituirla.
// =====================================================================

export interface DatosCorreoMfa {
  /** Código de 6 dígitos. Este módulo NUNCA lo registra, solo lo incrusta. */
  code: string;
  minutos: number;
  nombre?: string;
}

function escaparHtml(s: string): string {
  return s.replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!
  );
}

export function generarCorreoMfa({ code, minutos, nombre }: DatosCorreoMfa): {
  asunto: string;
  html: string;
  texto: string;
} {
  // El código se parte en dos grupos de 3 (123 456) SOLO para la lectura en
  // voz alta y el escaneo visual; el valor que hay que teclear son los 6
  // dígitos seguidos, y así se los diga el input del paso 2 (`maxLength=6`).
  const grupos = `${code.slice(0, 3)} ${code.slice(3)}`;
  const saludo = nombre ? `Hola, ${escaparHtml(nombre)}.` : "Hola.";

  const html = `<!doctype html>
<html lang="es">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head>
<body style="margin:0;padding:0;background:#faf9f5;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#faf9f5;padding:32px 16px;">
  <tr><td align="center">
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:420px;background:#ffffff;border:1px solid rgba(15,12,8,.12);border-radius:20px;">
      <tr><td style="padding:36px 32px 8px;text-align:center;">
        <table role="presentation" cellpadding="0" cellspacing="0" style="margin:0 auto 18px;">
          <tr><td style="width:52px;height:52px;border-radius:14px;background:#191915;color:#faf9f5;font:700 19px/52px Arial,Helvetica,sans-serif;text-align:center;">PT</td></tr>
        </table>
        <p style="margin:0 0 6px;font:500 20px/1.3 Arial,Helvetica,sans-serif;letter-spacing:-.2px;color:rgba(15,12,8,.92);">
          Verificación en dos pasos
        </p>
        <p style="margin:0;font:400 13px/1.5 Arial,Helvetica,sans-serif;color:rgba(15,12,8,.6);">
          ${saludo} Usa este código para entrar a Track Garantía.
        </p>
      </td></tr>

      <tr><td style="padding:20px 32px 4px;text-align:center;">
        <div style="display:inline-block;padding:16px 28px;border:1px solid #e5e2da;border-radius:12px;background:#fbfaf7;">
          <span style="font:700 32px/1 Menlo,Consolas,Georgia,monospace;letter-spacing:6px;color:rgba(15,12,8,.92);">${grupos}</span>
        </div>
        <p style="margin:14px 0 0;font:400 12.5px/1.5 Arial,Helvetica,sans-serif;color:rgba(15,12,8,.6);">
          Caduca en ${minutos} minutos y solo sirve una vez.
        </p>
      </td></tr>

      <tr><td style="padding:20px 32px 32px;">
        <p style="margin:0;font:400 12px/1.6 Arial,Helvetica,sans-serif;color:rgba(15,12,8,.64);border-top:1px solid rgba(15,12,8,.08);padding-top:16px;">
          ¿No pediste este código? Ignora este correo: nadie puede entrar a tu
          cuenta sin él, y sin acción tuya se invalida solo al vencer. Si
          ocurre más de una vez, avisa a sistemas@primetelecom.com.
        </p>
      </td></tr>
    </table>
    <p style="margin:16px 0 0;font:400 11px/1.5 Arial,Helvetica,sans-serif;color:rgba(15,12,8,.4);">
      Prime Telecom · Track Garantía — correo automático, no respondas a esta dirección.
    </p>
  </td></tr>
</table>
</body>
</html>`;

  const texto =
    `${saludo} Tu código de verificación de Track Garantía es: ${grupos}\n\n` +
    `Caduca en ${minutos} minutos y solo sirve una vez.\n\n` +
    `¿No lo pediste tú? Ignora este correo.`;

  return { asunto: `${grupos} es tu código de verificación`, html, texto };
}
