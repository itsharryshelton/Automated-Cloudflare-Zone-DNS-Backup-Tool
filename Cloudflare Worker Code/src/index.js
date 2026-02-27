export default {
  async fetch(request, env) {
    // ---------------------------------------------------------
    // Serve the HTML UI
    // ---------------------------------------------------------
    if (request.method === "GET") {
      const html = `
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="UTF-8">
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
          <title>Cloudflare Backup Onboarding</title>
          <script src="https://cdn.tailwindcss.com"></script>
          <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap" rel="stylesheet">
          <style>
            body { font-family: 'Inter', sans-serif; }
          </style>
        </head>
        <body class="bg-slate-50 flex items-center justify-center min-h-screen antialiased text-slate-900">
          
          <div class="bg-white p-8 sm:p-10 rounded-2xl shadow-xl border border-slate-100 w-full max-w-md mx-4">
            
            <div class="mb-8 text-center">
              <div class="inline-flex items-center justify-center w-12 h-12 rounded-full bg-blue-50 mb-4">
                <svg class="w-6 h-6 text-blue-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 8h14M5 8a2 2 0 110-4h14a2 2 0 110 4M5 8v10a2 2 0 002 2h10a2 2 0 002-2V8m-9 4h4"></path>
                </svg>
              </div>
              <h2 class="text-2xl font-bold tracking-tight text-slate-900">Protect Cloudflare Tenant</h2>
              <p class="text-sm text-slate-500 mt-2">Add a customer to the backup schedule for zone backups.</p>
            </div>

            <form id="provisionForm" class="space-y-5">
              <div>
                <label class="block text-sm font-semibold text-slate-700 mb-1">Customer Name (RowKey)</label>
                <input type="text" name="customerName" required placeholder="e.g. Microsoft" 
                  class="w-full px-4 py-2.5 rounded-lg border border-slate-300 focus:ring-2 focus:ring-blue-600 focus:border-blue-600 transition-colors placeholder-slate-400 outline-none text-sm">
              </div>
              
              <div>
                <label class="block text-sm font-semibold text-slate-700 mb-1">Cloudflare Account ID</label>
                <input type="text" name="accountId" required placeholder="x42xyz75c4fa634f82211ce000e9ea26" 
                  class="w-full px-4 py-2.5 rounded-lg border border-slate-300 focus:ring-2 focus:ring-blue-600 focus:border-blue-600 transition-colors placeholder-slate-400 outline-none text-sm font-mono">
              </div>

              <button type="submit" id="submitBtn" 
                class="w-full flex items-center justify-center bg-blue-600 hover:bg-blue-700 text-white font-medium py-2.5 px-4 rounded-lg transition-colors focus:ring-4 focus:ring-blue-200 outline-none mt-6">
                <svg id="spinner" class="animate-spin -ml-1 mr-3 h-5 w-5 text-white hidden" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
                  <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
                  <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
                </svg>
                <span id="btnText">Protect Customer</span>
              </button>
			  <p class="text-sm text-slate-500 mt-2">Harry Shelton</p>
            </form>

            <div id="statusMessage" class="hidden mt-6 p-4 rounded-lg text-sm font-medium text-center"></div>
            
          </div>

          <script>
            document.getElementById('provisionForm').addEventListener('submit', async (e) => {
              e.preventDefault(); // Stop the browser from navigating away
              
              const form = e.target;
              const btn = document.getElementById('submitBtn');
              const btnText = document.getElementById('btnText');
              const spinner = document.getElementById('spinner');
              const status = document.getElementById('statusMessage');

              // Set Loading State
              btn.disabled = true;
              btn.classList.add('opacity-80', 'cursor-not-allowed');
              spinner.classList.remove('hidden');
              btnText.textContent = 'Provisioning...';
              status.classList.add('hidden');

              try {
                const response = await fetch('/', {
                  method: 'POST',
                  body: new FormData(form)
                });
                
                const data = await response.json();

                // Show Success or Error
                status.classList.remove('hidden');
                if (response.ok) {
                  status.className = 'mt-6 p-4 rounded-lg text-sm font-medium text-center bg-green-50 text-green-700 border border-green-200';
                  status.textContent = data.message;
                  form.reset(); // Clear the inputs on success
                } else {
                  throw new Error(data.error || 'Something went wrong');
                }
              } catch (error) {
                status.classList.remove('hidden');
                status.className = 'mt-6 p-4 rounded-lg text-sm font-medium text-center bg-red-50 text-red-700 border border-red-200';
                status.textContent = error.message;
              } finally {
                // Reset Button State
                btn.disabled = false;
                btn.classList.remove('opacity-80', 'cursor-not-allowed');
                spinner.classList.add('hidden');
                btnText.textContent = 'Provision Tenant';
              }
            });
          </script>
        </body>
        </html>
      `;
      return new Response(html, { headers: { "Content-Type": "text/html" } });
    }

// ---------------------------------------------------------
    // Handle the API request and return JSON
    // ---------------------------------------------------------
    if (request.method === "POST") {
      try {
        const formData = await request.formData();
        const customerName = formData.get("customerName");
        const accountId = formData.get("accountId");

        // Auth with Entra ID
        const tokenResponse = await fetch(`https://login.microsoftonline.com/${env.TENANT_ID}/oauth2/v2.0/token`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
          body: new URLSearchParams({
            client_id: env.CLIENT_ID,
            client_secret: env.CLIENT_SECRET,
            scope: 'https://storage.azure.com/.default',
            grant_type: 'client_credentials'
          })
        });

        const tokenData = await tokenResponse.json();
        if (!tokenData.access_token) throw new Error("Failed to authenticate with Azure Entra ID.");

        // Insert into Azure Table Storage
        const tableUrl = `https://${env.STORAGE_ACCOUNT}.table.core.windows.net/${env.TABLE_NAME}`;
        const insertResponse = await fetch(tableUrl, {
          method: 'POST',
          headers: {
            'Authorization': `Bearer ${tokenData.access_token}`,
            'Content-Type': 'application/json',
            'Accept': 'application/json;odata=nometadata',
            'x-ms-version': '2019-02-02'
          },
          body: JSON.stringify({
            PartitionKey: "Cloudflare",
            RowKey: customerName,
            AccountId: accountId
          })
        });

        // Return JSON instead of plain text
        if (insertResponse.ok) {
          return Response.json({ message: "Tenant successfully added to the backup schedule." }, { status: 200 });
        } else {
          const errorText = await insertResponse.text();
          return Response.json({ error: `Azure Storage Error: ${errorText}` }, { status: 500 });
        }

      } catch (error) {
        return Response.json({ error: `Worker Error: ${error.message}` }, { status: 500 });
      }
    }

    return new Response("Method not allowed", { status: 405 });
  }
};
