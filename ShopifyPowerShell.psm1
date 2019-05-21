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
        [System.Text.Encoding]::UTF8.GetBytes($String)
    )
}

function Invoke-ShopifyRestAPIFunction{
    [cmdletbinding()]
    param(
        [Parameter(Mandatory)]$HttpMethod,
        [Parameter(Mandatory)]$ShopName,
        [Parameter(Mandatory)]$Resource,
        $Subresource,
        $Body,
        [hashtable]$Endpoints
    )
    
    $Credential = Get-ShopifyCredential
    $AuthToken = "$($Credential.UserName):$($Credential.GetNetworkCredential().Password)" | ConvertTo-Base64
    $Headers = @{
        Authorization = "Basic $AuthToken"
        "Content-Type" = "application/json"
    }

    $URIRoot = "https://$ShopName.myshopify.com/admin/$($Resource.toLower())"

    if ($Subresource){
        $URI = $URIRoot + ("/$Subresource").ToLower() + ".json"
    } else {
        $URI = $URIRoot + ".json"
    }    
    
    if ($Endpoints) {
        $URI += $Endpoints | Convert-HashtableToQueryString
    }
    
    do {
        try {
            $Response = Invoke-WebRequest -Uri $URI -Method $HttpMethod -Body $Body -Headers $Headers -ErrorAction Stop
            $StatusCode = $Response.StatusCode
            return $Response.Content | ConvertFrom-Json
        } catch [System.Net.WebException] {
            $StatusCode = $_.Exception.Response.StatusCode
            if ($StatusCode -eq 429) {
                $RetryDelay = [int]$_.Exception.Response.Headers["Retry-After"]
                Write-Warning -Message "Throttling for $RetryDelay seconds"
                Start-Sleep -Seconds $RetryDelay 
            } else {
                Write-Error $_
            }
        }
    } while ($StatusCode -eq 429)
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

    do {
        $Response = Invoke-RestMethod -Method POST -Headers $Headers -Uri $URI -Body $Body
        $Throttled = $Response.errors -and ($Response.errors[0].message -eq "Throttled")
        if ($Throttled) {
            $Response | Invoke-ShopifyAPIThrottle    
        } else {
            return $Response
        }
    } while ($Throttled)
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
    param (
        [Parameter(Mandatory)]$ShopName
    )
    $Body = @"
    {
        shop {
          products(first: 250) {
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

    Invoke-ShopifyAPIFunction -ShopName $ShopName -Body $Body
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

function Get-ShopifyRestProductCount {
    param (
        [Parameter(Mandatory)]$ShopName
    )
    Invoke-ShopifyRestAPIFunction -HttpMethod GET -ShopName $ShopName -Resource Products -Subresource Count | Select-Object -ExpandProperty count
}

function Get-ShopifyRestProductsAll {
    param (
       [Parameter(Mandatory)]$ShopName
    )

    $Limit = 250
    $Products = @()
    $Count = Get-ShopifyRestProductCount @PSBoundParameters
    $Pages = [System.Math]::Ceiling($Count/$Limit)

    for ($Page = 1; $Page -le $Pages; $Page++) {
        Write-Progress -Activity "Getting all Shopify products for $ShopName" -Status "Items retrieved: $($Products.Count) of $Count" -PercentComplete ($Page * 100 / $Pages)
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
        [ValidateSet("web","global")]$Channel,
        [switch]$ShowProgress
    )
    $Total = $Products.count
    $i = 0

    foreach ($Product in $Products) {
        if ($Total -and $ShowProgress) {
            Write-Progress -Activity "Updating product channel" -CurrentOperation $Product.title -PercentComplete ($i * 100 / $Total) -Status "$i of $Total"
        }
        $Body = [PSCustomObject]@{
            product = @{
                id = $Product.id
                published_scope = $Channel
            }
        } | ConvertTo-Json -Compress
    
        Invoke-ShopifyRestAPIFunction -HttpMethod PUT -ShopName $ShopName -Resource Products -Subresource $Product.id -Body $Body
        $i++
    }
    if ($Total -and $ShowProgress) {
        Write-Progress -Activity "Updating product channel" -Completed
    }
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

function New-ShopifyProduct {
    param (
        [Parameter(Mandatory)]$ShopName,
        [Parameter(Mandatory)]$Title,
        $Description,
        $Handle,
        $Barcode,
        $Price = 0,
        $Sku,
        [ValidateSet("CONTINUE","DENY")]$InventoryPolicy = "DENY",
        [ValidateSet("true","false")]$Tracked,
        [ValidateSet("FULFILLMENT_SERVICE","NOT_MANAGED","SHOPIFY")]$InventoryManagement,
        $ImageURL,
        $Vendor
        )

    $Mutation = @"
        mutation {
            productCreate(
                input: {
                    title: "$Title",
                    descriptionHtml: "$Description",
                    handle: "$Handle",
                    variants: [
                        {
                            barcode: "$Barcode",
                            price: "$Price",
                            sku: "$Sku",
                            inventoryPolicy: $InventoryPolicy,
                            inventoryItem: {
                                tracked: $Tracked
                            }
                            inventoryManagement: $InventoryManagement
                        }
                    ],
                    images: [
                        {
                            src: "$ImageURL"
                        }
                    ],
                    vendor: "$Vendor"
                }
            ) {
                product {
                    id
                    updatedAt
                    variants (first: 1) {
                        edges {
                            node {
                                inventoryItem {
                                    id
                                    sku
                                }
                            }
                        }
                    } 
                }
                userErrors {
                    field
                    message
                }
            }
        }    
"@
    $Response = Invoke-ShopifyAPIFunction -ShopName $ShopName -Body $Mutation
    if ($Response.data.productCreate.userErrors) {
        throw $Response.data.productCreate.userErrors[0].message
    } else {
        return $Response.data.productCreate.product
    }
}

function Find-ShopifyProduct {
    param (
        [Parameter(Mandatory,ParameterSetName = "SKU")]$SKU,
        [Parameter(Mandatory,ParameterSetName = "Title")]$Title,
        [Parameter(Mandatory)]$ShopName
    )
        
    $Products = @()
    $CurrentCursor = ""
    
    do {
        $QraphQLQuery = @"
            {
                products(first: 5, 
                    $(if ($CurrentCursor) {"after:`"$CurrentCursor`","} ) 
                    $(
                        if ($Title) {"query:`"title:*$Title*`""}
                        elseif ($SKU) {"query:`"sku:$SKU`""}
                    )
                ) {
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
                                        price
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

function Update-ShopifyProduct {
    param (
        [Parameter(Mandatory)]$ShopName,
        [Parameter(Mandatory)]$Id,
        [Parameter(Mandatory)]$Title,
        $Description,
        $Handle,
        $Barcode,
        $Price,
        $Sku,
        [ValidateSet("CONTINUE","DENY")]$InventoryPolicy,
        [ValidateSet("true","false")]$Tracked,
        [ValidateSet("FULFILLMENT_SERVICE","NOT_MANAGED","SHOPIFY")]$InventoryManagement,
        $ImageURL,
        $Vendor
        )

    $Mutation = @"
        mutation {
            productUpdate(
                input: {
                    id: "$Id"
                    title: "$Title",
                    descriptionHtml: "$Description",
                    handle: "$Handle",
                    variants: [
                        {
                            barcode: "$Barcode",
                            price: "$Price",
                            sku: "$Sku",
                            inventoryPolicy: $InventoryPolicy,
                            inventoryItem: {
                                tracked: $Tracked
                            }
                            inventoryManagement: $InventoryManagement
                        }
                    ],
                    images: [
                        {
                            src: "$ImageURL"
                        }
                    ],
                    vendor: "$Vendor"
                }
            ) {
                product {
                    id
                    updatedAt
                    variants (first: 1) {
                        edges {
                            node {
                                inventoryItem {
                                    id
                                    sku
                                }
                            }
                        }
                    } 
                }
                userErrors {
                    field
                    message
                }
            }
        }    
"@
    $Response = Invoke-ShopifyAPIFunction -ShopName $ShopName -Body $Mutation
    if ($Response.data.productUpdate.userErrors) {
        throw $Response.data.productUpdate.userErrors[0].message
    } else {
        return $Response.data.productUpdate.product
    }
}

function Remove-ShopifyProduct {
    param (
        [Parameter(Mandatory)]$GlobalId,
        [Parameter(Mandatory)]$ShopName
    )

    $Base64EncodedId = $GlobalId | ConvertTo-Base64

    $Mutation = @"
    mutation {
        productDelete(input: { id: "$Base64EncodedId" } ) {
          deletedProductId
          userErrors {
            field
            message
          }
        }
      }
"@
    # Invoke-ShopifyAPIFunction -ShopName $ShopName -Body $Mutation
    $Response = Invoke-ShopifyAPIFunction -ShopName $ShopName -Body $Mutation
    if ($Response.data.productDelete.userErrors) {
        throw $Response.data.productDelete.userErrors[0].message
    } else {
        return $Response.data.productDelete.deletedProductId
    }
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
    
    $Response = Invoke-ShopifyAPIFunction -ShopName $ShopName -Body $Mutation
    if ($Response.data.inventoryActivate.userErrors) {
        throw $Response.data.inventoryActivate.userErrors[0].message
    } else {
        return $Response.data.inventoryActivate.inventoryLevel.id
    }
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

function New-ShopifyImageByURL {
    # Does not work currently
    param (
        [Parameter(Mandatory)]$ImageUrl,
        [Parameter(Mandatory)]$ProductId,
        [Parameter(Mandatory)]$ShopName
    )
    
    $Body = @{
        image = @{
            src = $ImageUrl
        }
    } | ConvertTo-Json -Compress

    Invoke-ShopifyRestAPIFunction -HttpMethod POST -ShopName $ShopName -Resource Products -Subresource "$ProductId/images" -Body $Body
}

function Get-ShopifyPublications {
    param (
        [Parameter(Mandatory)]$ShopName,
        $ResultSize = 5
    )
    $Query = @"
        query {
            publications(first: $ResultSize) {
                edges {
                    node {
                        id
                        name
                    }
                }
            }
        }
"@
    Invoke-ShopifyAPIFunction -ShopName $ShopName -Body $Query
}

function Set-ShopifyInventoryItemTrackedAttribute {
    param (
        [Parameter(Mandatory)]$ShopName,
        [Parameter(Mandatory)]$InventoryItemId,
        [Parameter(Mandatory)]
        [ValidateSet("true","false")]$TrackedValue
    )
    
    $EncodedItemId = "gid://shopify/InventoryItem/$InventoryItemId" | ConvertTo-Base64
    $Mutation = @"
        mutation {
            inventoryItemUpdate(
                id: "$($EncodedItemId)"
                input: {
                    tracked: $TrackedValue
                }
            ) {
                inventoryItem {
                    id
                    tracked
                }
                userErrors {
                    field
                    message
                }
            }
        }
"@
    $Response = Invoke-ShopifyAPIFunction -ShopName $ShopName -Body $Mutation
    if ($Response.data.inventoryItemUpdate.userErrors) {
        throw $Response.data.inventoryItemUpdate.userErrors[0].message
    } else {
        return $Response.data.inventoryItemUpdate.inventoryItem
    }
}

function Get-ShopifyInventoryItemLocations {
    param (
        [Parameter(Mandatory)]$ShopName,
        [Parameter(Mandatory)]$InventoryItemId
    )
    do {
        $Query = @"
            query {
                inventoryItem(id: "gid://shopify/InventoryItem/$InventoryItemId") {
                        inventoryLevels(first: 5) {
                            edges {
                                node {
                                    location {
                                        id
                                        name
                                    }
                                }
                                cursor
                            }
                            pageInfo {
                                hasNextPage
                            }
                        }
                    }
                }   
"@
        $Response = Invoke-ShopifyAPIFunction -ShopName $ShopName -Body $Query
        $CurrentCursor = $Response.data.inventoryItem.inventoryLevels.edges | Select-Object -Last 1 -ExpandProperty cursor
        $Locations += $Response.data.inventoryItem.inventoryLevels.edges.node | Select-Object -ExpandProperty location
    } while ($Response.data.inventoryItem.inventoryLevels.pageInfo.hasNextPage)
    return $Locations
}