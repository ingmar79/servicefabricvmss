

add-type @"
    using System.Net;
    using System.Security.Cryptography.X509Certificates;
    public class TrustAllCertsPolicy : ICertificatePolicy {
        public bool CheckValidationResult(
            ServicePoint srvPoint, X509Certificate certificate,
            WebRequest request, int certificateProblem) {
            return true;
        }
    }
"@
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy

    $serviceUrl = "https://2a1ecc99-13fd-46e2-a3c8-9e59917e5717.cloudapp.net/resources/"
    #$serviceUrl ="http://10.0.2.5:5000/activities/"
    while($true) { 
        Invoke-WebRequest -Uri  $serviceUrl |Select -ExpandProperty RawContent
        Start-Sleep -Milliseconds 1000 
        }
