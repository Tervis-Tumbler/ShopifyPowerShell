#Requires -Modules WebServicesPowerShellProxyBuilder

function Set-ShopifyCredential {
    param (
        [Parameter(Mandatory)]$Credential
    )
    $Script:Credential = $Credential
}
function Get-ShopifyCredential {
    if ($Script:Credential) {
        $Script:Credential
    } else {
        Throw "You need to call Set-ShopifyCredential"
    }
}

function Convert-HashtableToQueryString {
    param (
        [Parameter(Mandatory,ValueFromPipeline)]
        [hashtable]$Hashtable
    )

    $QueryString = "?"

    foreach ($Key in $Hashtable.Keys) {
        $QueryString += "$Key=$($Hashtable[$Key])&"
    }

    return $QueryString.TrimEnd("&")
}

function Invoke-ShopifyRestAPIFunction{
    [cmdletbinding()]
    param(
        $HttpMethod,
        $ShopName,
        $Resource,
        $Subresource,
        $Body,
        [hashtable]$Endpoints
        )
    
    $Credential = Get-ShopifyCredential

    $URIRoot = "https://$($Credential.UserName):$($Credential.GetNetworkCredential().Password)@$ShopName.myshopify.com/admin/$($Resource.toLower())"

    if ($Subresource){
        $URI = $URIRoot + ("/$Subresource").ToLower() + ".json"
    } else {
        $URI = $URIRoot + ".json"
    }    
    
    if ($Endpoints) {
        $URI += $Endpoints | Convert-HashtableToQueryString
    }
    
    $Response = Invoke-WebRequest -Credential $Credential -Uri $URI -Method $HttpMethod -Body $Body -ContentType "application/json"

    $ApiCallLimitStats = $Response.Headers.'X-Shopify-Shop-Api-Call-Limit' -split "/"
    if ($ApiCallLimitStats[0]/$ApiCallLimitStats[1] -gt .9) {
        Write-Progress -Activity "Throttling Shopify REST API"
        Start-Sleep -Seconds 10
        Write-Progress -Activity "Throttling Shopify REST API" -Completed
    }

    $Response.Content | ConvertFrom-Json
}
function Invoke-ShopifyAPIFunction{
    [CmdletBinding()]
    param(
        [parameter(Mandatory)]$ShopName,
        [parameter(Mandatory)]$HttpMethod,
        [parameter(Mandatory)]$Body
    )
    $Credential = Get-ShopifyCredential
    $URI = "https://$ShopName.myshopify.com/admin/api/graphql.json"
    $Headers = @{
        "X-Shopify-Access-Token" = "$($Credential.GetNetworkCredential().Password)"
        "Content-Type" = "application/graphql"
    }

    $Response = Invoke-RestMethod -Method $HttpMethod -Headers $Headers -ContentType "application/graphql" -Uri $URI -Body $Body
    $Response
}
function Invoke-ShopifyGraphQLTest{
    $Body = @"
    {
        shop {
          products(first: 5) {
            edges {
              node {
                id
                handle
              }
            }
            pageInfo {
              hasNextPage
            }
          }
        }
      }
"@

    Invoke-ShopifyAPIFunction -ShopName ospreystoredev -HttpMethod Post -Body $Body
}
function Get-ShopifyRestInventoryItems{
    [cmdletbinding()]
    param(
        [Parameter(mandatory)]$ShopName,
        [Parameter(mandatory)]$ItemIDsSeparatedByCommas
    )
    #$ItemIDsSeparatedByCommas needs to be refactored.

    $Resource = "inventory_items.json?ids=$ItemIDsSeparatedByCommas"

    Invoke-ShopifyRestAPIFunction -HttpMethod Get -Resource $Resource -ShopName $ShopName
}

function Get-ShopifyRestShop{
    [cmdletbinding()]
    param(
        [Parameter(mandatory)]$ShopName
    )
    Invoke-ShopifyRestAPIFunction -HttpMethod Get -Resource Shop -ShopName $ShopName
}

function Get-ShopifyRestProducts{
    [cmdletbinding()]
    param(
        [parameter(mandatory)]$ShopName
    )
    Invoke-ShopifyRestAPIFunction -HttpMethod Get -Resource Products -ShopName $ShopName
}

function New-ShopifyRestProduct{
    [cmdletbinding()]
    param(
        [parameter(mandatory)]$ShopName,
        [parameter(mandatory)]$Title,
        [parameter(mandatory)]$Description,
        [parameter(mandatory)]$EBSItemNumber,
        [parameter(mandatory)]$UPC,
        [parameter(mandatory)]$Price,
        $InventoryQuantity = 0
    )
    $Body = @"
{
    "product": {
        "title": "$Title",
        "body_html": "$Description",
        "variants: [
            {
                "price":"$Price",
                "sku":"$EBSItemNumber",
                "barcode":"$UPC"
                "inventory_quantity":"$InventoryQuantity"
            }
        ]
    }
}    
"@
    Invoke-ShopifyRestAPIFunction -HttpMethod Post  -Resource Products @PSBoundParameters
}

function Get-ShopifyRestProductsAll {
    param (
       [Parameter(Mandatory)]$ShopName
    )

    $Limit = 250
    $Products = @()
    $Page = 1
    $Count = Invoke-ShopifyRestAPIFunction -HttpMethod GET -ShopName $ShopName -Resource Products -Subresource Count | Select-Object -ExpandProperty count

    for ($i = 0; $i -lt $Count; $i += $Limit) {
        Write-Progress -Activity "Getting all Shopify products for $ShopName" -Status "Items retrieved: $i" -PercentComplete ($i * 100 / $Count)
        $Query = @{limit=$Limit;page=$Page}
        $Response = Invoke-ShopifyRestAPIFunction -HttpMethod GET -ShopName $ShopName -Resource Products -Endpoints $Query | Select-Object -ExpandProperty products
        $Products += $Response
        $Page++
    }
    Write-Progress -Activity "Getting all Shopify products for $ShopName" -Completed

    return $Products
}

function Set-ShopifyRestProductChannel {
    param (
        [Parameter(Mandatory)]$ShopName,
        [Parameter(Mandatory)]$Products,
        [Parameter(Mandatory)]
        [ValidateSet("web","global")]$Channel
    )
    $Total = $Products.count
    $i = 0

    foreach ($Product in $Products) {
        Write-Progress -Activity "Updating product channel" -CurrentOperation $Product.title -PercentComplete ($i * 100 / $Total) -Status "$i of $Total"
        $Body = [PSCustomObject]@{
            product = @{
                id = $Product.id
                published_scope = $Channel
            }
        } | ConvertTo-Json -Compress
    
        Invoke-ShopifyRestAPIFunction -HttpMethod PUT -ShopName $ShopName -Resource Products -Subresource $Product.id -Body $Body
        $i++
    }
    Write-Progress -Activity "Updating product channel" -Completed
}
