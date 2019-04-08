#Requires -Modules WebServicesPowerShellProxyBuilder

function Set-ShopifyCredential {
    param (
        [Parameter(Mandatory)][pscredential]$Credential
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

function ConvertTo-Base64 {
    param (
        [Parameter(Mandatory,ValueFromPipeline)][string]$String
    )

    return [System.Convert]::ToBase64String(
        [System.Text.Encoding]::Unicode.GetBytes($String)
    )
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
    
    $Response = Invoke-WebRequest -Credential $Credential -Uri $URI -Method $HttpMethod -Body $Body -ContentType "application/json" -

    $ApiCallLimitStats = $Response.Headers.'X-Shopify-Shop-Api-Call-Limit' -split "/"
    if ($ApiCallLimitStats -and ($ApiCallLimitStats[0]/$ApiCallLimitStats[1] -gt .9)) {
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
        [parameter(Mandatory)]$Body
    )
    $Credential = Get-ShopifyCredential
    $URI = "https://$ShopName.myshopify.com/admin/api/graphql.json"
    $Headers = @{
        "X-Shopify-Access-Token" = "$($Credential.GetNetworkCredential().Password)"
        "Content-Type" = "application/graphql"
    }

    $Response = Invoke-RestMethod -Method POST -Headers $Headers -ContentType "application/graphql" -Uri $URI -Body $Body
    while ($Response.errors -and ($Response.errors[0].message -eq "Throttled")) {
        $Response | Invoke-ShopifyAPIThrottle
        $Response = Invoke-RestMethod -Method POST -Headers $Headers -ContentType "application/graphql" -Uri $URI -Body $Body
    }
    $Response
}

function Invoke-ShopifyAPIThrottle {
    param (
        [Parameter(Mandatory,ValueFromPipeline)]$Response
    )
    process {
        $RequestedQueryCost = $Response.extensions.cost.requestedQueryCost
        $RestoreRate = $Response.extensions.cost.throttleStatus.restoreRate
        $CurrentlyAvailable = $Response.extensions.cost.throttleStatus.currentlyAvailable

        if ($CurrentlyAvailable -lt $RequestedQueryCost -and $RestoreRate -gt 0) {
            $SecondsToWait = [System.Math]::Ceiling( ($RequestedQueryCost - $CurrentlyAvailable) / $RestoreRate )
            Write-Warning "Throttling for $SecondsToWait second$(if ($SecondsToWait -gt 1) { "s" })"
            Start-Sleep -Seconds $SecondsToWait
        }
    }
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

    Invoke-ShopifyAPIFunction -ShopName ospreystoredev -Body $Body
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

function New-ShopifyRestProduct {
    [cmdletbinding()]
    param(
        [parameter(mandatory)]$ShopName,
        [parameter(mandatory)]$Title,
        <# [parameter(mandatory)] #>$Body_HTML,
        <# [parameter(mandatory)] #>$SKU,
        <# [parameter(mandatory)] #>$Barcode,
        <# [parameter(mandatory)] #>$Price,
        [ValidateSet("web","global")]$Published_Scope = "global",
        $Inventory_Quantity = 0
    )
    
    $Body = [PSCustomObject]@{
        product = @{
            title = $Title
            body_html = $Body_HTML
            published_scope = $Published_Scope
            variants = @(
                @{
                    price = $Price
                    sku = $SKU
                    barcode = $Barcode
                    inventory_quantity = $Inventory_Quantity
                }
            )
        }
    } | ConvertTo-Json -Compress -Depth 3

    Invoke-ShopifyRestAPIFunction -HttpMethod Post -Resource Products -ShopName $ShopName -Body $Body
}

function Get-ShopifyRestProductsAll {
    param (
       [Parameter(Mandatory)]$ShopName
    )

    $Limit = 250
    $Products = @()
    $Count = Invoke-ShopifyRestAPIFunction -HttpMethod GET -ShopName $ShopName -Resource Products -Subresource Count | Select-Object -ExpandProperty count
    $Pages = [System.Math]::Ceiling($Count/$Limit)

    for ($Page = 1; $Page -le $Pages; $Page++) {
        Write-Progress -Activity "Getting all Shopify products for $ShopName" -Status "Items retrieved: $($Products.Count)" -PercentComplete ($Page * 100 / $Pages)
        $Query = @{limit=$Limit;page=$Page}
        $Response = Invoke-ShopifyRestAPIFunction -HttpMethod GET -ShopName $ShopName -Resource Products -Endpoints $Query | Select-Object -ExpandProperty products
        $Products += $Response
    }
    Write-Progress -Activity "Getting all Shopify products for $ShopName" -Completed

    return $Products
}

function Get-ShopifyRestLocations {
    param (
        [Parameter(Mandatory)]$ShopName
    )

    Invoke-ShopifyRestAPIFunction -HttpMethod GET -ShopName $ShopName -Resource Locations | Select-Object -ExpandProperty Locations
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

function Remove-ShopifyRestProduct {
    param (
        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]$ID,
        [Parameter(ValueFromPipelineByPropertyName)]$Title,
        [Parameter(Mandatory)]$ShopName
    )
    begin {
        Write-Progress -Activity "Removing products"
        $ItemCount = 0
    }
    process {
        try {
            $ItemCount++
            Write-Progress -Activity "Removing products" -Status "Removing $ID $Title" -CurrentOperation "Total: $ItemCount"
            Invoke-ShopifyRestAPIFunction -HttpMethod DELETE -ShopName $ShopName -Resource Products -Subresource $ID -ErrorAction Stop | Out-Null
        } catch {
            Write-Warning -Message "Could not remove product $ID $Title"
        }
    }
}

function Find-ShopifyProduct {
    param (
        [Parameter(Mandatory)]$ShopName,
        [Parameter(Mandatory)]$Title
        )
        
    $Products = @()
    $CurrentCursor = ""
    
    do {
        $QraphQLQuery = @"
            {
                products(first: 50, $(if ($CurrentCursor) {"after:`"$CurrentCursor`","} ) query:`"title:*$Title*`") {
                    edges {
                        node {
                            title
                            id
                            handle
                            variants(first: 1) {
                                edges {
                                    node {
                                        title
                                        id
                                        barcode
                                        inventoryItem {
                                            id
                                        }
                                        sku
                                    }
                                }
                            }
                        }
                        cursor
                    }
                    pageInfo {
                        hasNextPage
                    }           
                }
            }    
"@
        $Response = Invoke-ShopifyAPIFunction -ShopName $ShopName -Body $QraphQLQuery
        $CurrentCursor = $Response.data.products.edges | Select-Object -Last 1 -ExpandProperty cursor
        $Products += $Response.data.products.edges.node
    } while ($Response.data.products.pageInfo.hasNextPage)
    return $Products
}

function Invoke-ShopifyInventoryActivate {
    param (
        [Parameter(Mandatory)]$InventoryItemId,
        [Parameter(Mandatory)]$LocationId,
        [Parameter(Mandatory)]$ShopName
    )
    
    $EncodedItemId = "gid://shopify/InventoryItem/$InventoryItemId" | ConvertTo-Base64
    $EncodedLocationId = "gid://shopify/Location/$LocationId" | ConvertTo-Base64

    $Mutation = @"
        mutation InventoryActivate {
            inventoryActivate (inventoryItemId: "$EncodedItemId", locationId: "$EncodedLocationId") {
                inventoryLevel {
                    id
                }
                userErrors {
                    field
                    message
                }
            }
        }
"@
    
    Invoke-ShopifyAPIFunction -ShopName $ShopName -Body $Mutation
}

function Set-ShopifyProductVariantInventoryPolicy {
    param (
        [Parameter(Mandatory)]$ProductVariantId,
        [Parameter(Mandatory)][ValidateSet("DENY","CONTINUE")]$InventoryPolicy,
        [Parameter(Mandatory)]$ShopName
    )

    $Mutation = @"
    mutation SetProductVariantInventoryPolicy {
        productVariantUpdate (input: {inventoryPolicy:$InventoryPolicy, id: "gid://shopify/ProductVariant/$ProductVariantId"}) {
            product {
                id
            }
            productVariant {
                id
            }
            userErrors {
                field
                message
            }
        }
    }
"@
    
    Invoke-ShopifyAPIFunction -ShopName $ShopName -Body $Mutation
}
