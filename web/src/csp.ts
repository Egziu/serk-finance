// The server's Content-Security-Policy admits only <style> elements carrying this page's nonce.
export const nonce = document.querySelector('meta[name="csp-nonce"]')?.getAttribute("content") ?? undefined;
