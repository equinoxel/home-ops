# How to Force Plex Registration via Web

When deploying Plex Media Server in a modern containerized environment, it will initially start in an "unclaimed" state. Plex's built-in security features strongly restrict the administrative setup wizard: you can only claim a new server if your browser is on the same local subnet as the Plex Server itself.

If you are deploying Plex behind a reverse proxy (like Envoy or Nginx), or if your browser is on a different VLAN/subnet than the Kubernetes pods, visiting `https://plex.yourdomain.com/web` will show the Plex interface but **will not show the Server setup wizard**, preventing you from claiming it.

Here is the step-by-step tutorial on how to force the server registration using a local port-forward:

## Prerequisites
- `kubectl` installed and configured with access to your cluster
- Your Plex HelmRelease must be successfully deployed and the pod running

## Step-by-Step Guide

### 1. Locate the running Plex Pod
First, find the exact name of your Plex pod. By default, it runs in the `media` namespace.

```bash
kubectl get pods -n media | grep plex
```
*Note the pod name, which should look something like `plex-7b56f8f554-abcde`.*

### 2. Forward the local Plex port (32400)
To convince Plex that you are accessing it locally, use `kubectl port-forward` to map the pod's port `32400` directly to your machine.

Run the following command in your terminal (replacing `<plex-pod-name>` with the name you found in Step 1):

```bash
kubectl port-forward -n media pod/<plex-pod-name> 32400:32400
```
*Leave this terminal window open and running. It establishes a direct, local connection to the server.*

### 3. Access the Setup Wizard via Localhost
Open a fresh Incognito or Private browsing window (this prevents cached Plex tokens from interfering).

In the address bar, connect to your forwarded local port exactly like this:
```url
http://localhost:32400/web
```
*(Do not use HTTPS/SSL for this local connection).*

### 4. Claim the Server
1. Log in with your primary Plex account credentials.
2. Because you are accessing the server via `localhost`, Plex recognizes you as the local administrator.
3. The Initial Setup screen will appear. Follow the prompts to name the server.
4. Ensure the **"Allow me to access my media outside my home"** checkbox is selected during the wizard.
5. Add your media libraries if your storage is already mounted.
6. Click **Done** to finish claiming the server.

### 5. Finalize and Cleanup
You can now close the browser tab. Return to your terminal and stop the port-forward by pressing `Ctrl+C`.

Your Plex Media Server is now permanently linked to your Plex account. You can now access and manage it normally through your public domain URL (e.g., `https://plex.yourdomain.com`).
