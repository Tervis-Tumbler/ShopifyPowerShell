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
        [hashtable]$Endpoints,
        $APIVersion = "2020-04"
    )
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $Credential = Get-ShopifyCredential
    $AuthToken = "$($Credential.UserName):$($Credential.GetNetworkCredential().Password)" | ConvertTo-Base64
    $Headers = @{
        Authorization = "Basic $AuthToken"
        "Content-Type" = "application/json"
    }

    $URIRoot = "https://$ShopName.myshopify.com/admin/api/$APIVersion/$($Resource.toLower())"

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
            $Response = Invoke-WebRequest -UseBasicParsing -Uri $URI -Method $HttpMethod -Body $Body -Headers $Headers -ErrorAction Stop
            $StatusCode = $Response.StatusCode
            return $Response.Content | ConvertFrom-Json
        } catch [System.Net.WebException] {
            $StatusCode = $_.Exception.Response.StatusCode
            if ($StatusCode -eq 429) {
                $RetryDelay = [int]$_.Exception.Response.Headers["Retry-After"]
                Write-Warning -Message "Throttling for $RetryDelay seconds"
                Start-Sleep -Seconds $RetryDelay 
            } elseif ($StatusCode -eq 503) {
                Write-Warning -Message "Received 503: Service Unavailabe. Retrying in 1 second"
                Start-Sleep -Seconds 1
            } elseif ($StatusCode -eq 504) {
                Write-Warning -Message "Received 504: Gateway Timeout. Retrying in 1 second"
                Start-Sleep -Seconds 1
            } else {
                throw $_
            }
        } catch {
            throw $_
        }
    } while ($StatusCode -in 429,503,504)
}

function Invoke-ShopifyAPIFunction{
    [CmdletBinding()]
    param(
        [parameter(Mandatory)]$ShopName,
        [parameter(Mandatory)]$Body,
        $APIVersion = "2020-04"
    )
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $Credential = Get-ShopifyCredential
    $URI = "https://$ShopName.myshopify.com/admin/api/$APIVersion/graphql.json"
    $Headers = @{
        "X-Shopify-Access-Token" = "$($Credential.GetNetworkCredential().Password)"
        "Content-Type" = "application/graphql"
    }

    do {
        try {
            $Response = Invoke-RestMethod -Method POST -Headers $Headers -Uri $URI -Body $Body
            $Throttled = $Response.errors -and ($Response.errors[0].message -eq "Throttled")
            if ($Throttled) {
                $Response | Invoke-ShopifyAPIThrottle    
            } else {
                return $Response
            }
        } catch [System.Net.WebException] {
            $StatusCode = $_.Exception.Response.StatusCode
            if ($StatusCode -eq 503) {
                Write-Warning -Message "Received 503: Service Unavailabe. Retrying in 1 second"
                Start-Sleep -Seconds 1
            } elseif ($StatusCode -eq 504) {
                Write-Warning -Message "Received 504: Gateway Timeout. Retrying in 1 second"
                Start-Sleep -Seconds 1
            }
            else {
                throw $_
            }
        } catch {
            throw $_
        }
    } while ($Throttled -or ($StatusCode -in 503,504))
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

function Get-ShopifyRestProduct {
    [cmdletbinding()]
    param(
        [parameter(mandatory)]$ShopName,
        [Parameter(Mandatory)]$ProductId
    )
    Invoke-ShopifyRestAPIFunction -HttpMethod Get -Resource Products -ShopName $ShopName -Subresource $ProductId
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
        $Response = Invoke-ShopifyRestAPIFunction -HttpMethod GET -ShopName $ShopName -Resource Products -Endpoints $Query -APIVersion "2019-04" | Select-Object -ExpandProperty products
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
        [ValidateSet("true","false",IgnoreCase = $false)]$Tracked,
        [ValidateSet("FULFILLMENT_SERVICE","NOT_MANAGED","SHOPIFY")]$InventoryManagement,
        $ImageURL,
        $Vendor,
        [ValidateSet("true","false",IgnoreCase = $false)]$Taxable = "true",
        $MetafieldEBSDescription = "N/A"
    )

    $Mutation = @"
        mutation {
            productCreate(
                input: {
                    title: "$Title",
                    descriptionHtml: "$Description",
                    handle: "$Handle",
                    metafields: [
                        {
                            namespace: "tervis",
                            key: "ebsDescription",
                            value: "$MetafieldEBSDescription",
                            valueType: STRING
                        }
                    ]
                    variants: [
                        {
                            barcode: "$Barcode",
                            price: "$Price",
                            taxable: $Taxable,
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
                    tags
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
        [Parameter(Mandatory)]$ShopName,
        [Parameter(Mandatory,ParameterSetName = "SKU")]$SKU,
        [Parameter(Mandatory,ParameterSetName = "Title")]$Title,
        $MetafieldNamespace
    )
        
    $Products = @()
    $CurrentCursor = ""
    
    do {
        $QraphQLQuery = @"
            {
                products(first: 5, 
                    $(if ($CurrentCursor) {"after:`"$CurrentCursor`","} ) 
                    $(
                        if ($Title) {"query:`"'*$Title*'`""}
                        elseif ($SKU) {"query:`"sku:$SKU`""}
                    )
                ) {
                    edges {
                        node {
                            title
                            id
                            legacyResourceId
                            handle
                            tags
                            featuredImage {
                                id
                            }
                            metafields (
                                first: 5
                                namespace: "$MetafieldNamespace"
                            ) {
                                edges { 
                                    node {
                                        id
                                        namespace
                                        key
                                        value
                                        valueType
                                    }
                                }
                            }
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

function Find-ShopifyProductVariant {
    param (
        [Parameter(Mandatory)]$ShopName,
        [Parameter(Mandatory)]$SKU
    )
    $Query = @"
        {
            productVariants(
                query:"sku:$SKU"
                first: 1
            ) {
                edges {
                    node {
                        id
                        sku
                        image {
                            id
                        }
                        product {
                            id
                            title
                            images (first:20) {
                                edges {
                                    node {
                                        id
                                        altText
                                        originalSrc
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
"@
    $Response = Invoke-ShopifyAPIFunction -ShopName $ShopName -Body $Query
    return $Response.data.productVariants.edges.node
}

function Update-ShopifyProduct {
    param (
        [Parameter(Mandatory)]$ShopName,
        [Parameter(Mandatory)]$Id,
        [Parameter(Mandatory)]$Title,
        $Description,
        $Handle,
        [Parameter(Mandatory)]$VariantGID,
        $Barcode,
        $Price,
        $Sku,
        [ValidateSet("CONTINUE","DENY")]$InventoryPolicy,
        [ValidateSet("true","false",IgnoreCase = $false)]$Tracked,
        [ValidateSet("FULFILLMENT_SERVICE","NOT_MANAGED","SHOPIFY")]$InventoryManagement,
        $ImageURL,
        $Vendor,
        $Metafields
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
                            id: "$VariantGID"
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
                    $(
                        if ($Metafields) {
                            $MetafieldObjects = foreach ($Metafield in $Metafields) {
@"
                        {
                            $(if ($Metafield.id) { "id: `"$($Metafield.id)`"" })
                            namespace: "$($Metafield.namespace)"
                            key: "$($Metafield.key)"
                            value: "$($Metafield.value)"
                            valueType: $($Metafield.valueType)
                        }
"@
                            }
                            "metafields: [`n" + $($MetafieldObjects -join ",`n") + "`n`t`t`t`t`t]"
                        }
                    )
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
                    tags
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
    } elseif ($Response.errors) {
        throw $Response.errors.message
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
    $Locations = @()
    do {
        $Query = @"
            query {
                inventoryItem(id: "gid://shopify/InventoryItem/$InventoryItemId") {
                        inventoryLevels(
                                first: 5
                                $(if ($CurrentCursor) {", after:`"$CurrentCursor`""} )
                            ) {
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
        $Locations += $Response.data.inventoryItem.inventoryLevels.edges.node.location
    } while ($Response.data.inventoryItem.inventoryLevels.pageInfo.hasNextPage)
    return $Locations
}

function Get-ShopifyOrders {
    param (
        [Parameter(Mandatory)]$ShopName,
        $QueryString
    )

    $Query = {
        param ($QueryString, $OrderCursor, $LineItemCursor, $EventCursor)
        @"
        query {
            orders(first: 1, query:"$QueryString"
                $(if ($OrderCursor) {", after:`"$OrderCursor`""} )
            ) {
                edges {
                    node {
                        id
                        legacyResourceId
                        createdAt
                        tags
                        customAttributes {
                            key
                            value
                        }
                        customer {
                            displayName
                            firstName
                            lastName
                            defaultAddress {
                                address1
                                address2
                                city
                                province
                                zip
                                name
                                countryCodeV2
                            }
                        }
                        physicalLocation {
                            name
                            address {
                                city
                            }
                        }
                        fulfillable
                        lineItems(first: 1 $(if ($LineItemCursor) {", after:`"$LineItemCursor`""} )) {
                            edges {
                                node {
                                    name
                                    sku
                                    quantity
                                    variant {
                                        barcode
                                    }
                                    originalUnitPriceSet {
                                        shopMoney {
                                            amount
                                        }
                                    }
                                    discountedUnitPriceSet {
                                        shopMoney {
                                            amount
                                        }
                                    }
                                    discountedTotalSet {
                                        shopMoney {
                                            amount
                                        }
                                    }
                                    taxLines {
                                        priceSet {
                                            shopMoney {
                                                amount
                                            }
                                        }
                                    }
                                    customAttributes {
                                        key
                                        value
                                    }
                                }
                                cursor
                            }
                            pageInfo {
                                hasNextPage
                            }
                        }
                        shippingLine {
                            discountedPriceSet {
                                shopMoney {
                                    amount
                                }
                            }
                            taxLines {
                                priceSet {
                                    shopMoney {
                                        amount
                                    }
                                }
                            }
                        }
                        discountCode
                        cartDiscountAmountSet {
                            shopMoney {
                                amount
                            }
                        }
                        totalDiscountsSet {
                            shopMoney {
                                amount
                            }
                        }
                        events(first: 1 $(if ($EventCursor) {", after:`"$EventCursor`""} )) {
                            edges {
                                node {
                                    id
                                    message
                                }
                                cursor
                            }
                            pageInfo {
                                hasNextPage
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
    }
    $Orders = @()
    do {
        $Response = Invoke-ShopifyAPIFunction -ShopName $ShopName -Body $Query.Invoke($QueryString, $CurrentOrderCursor, $LineItemCursor, $EventCursor)
        try {
            $Retry = $false
            if (-not $Response.data.orders.edges) {break}
            $CurrentOrder = $Response.data.orders.edges[0].node
    
            $NextOrderCursor = $Response.data.orders.edges[0].cursor
            $LineItemCursor = $Response.data.orders.edges[0].node.lineItems.edges[0].cursor
            $LineItemHasNextPage = $Response.data.orders.edges[0].node.lineItems.pageInfo.hasNextPage
            $EventCursor = $Response.data.orders.edges[0].node.events.edges[0].cursor
            $EventHasNextPage = $Response.data.orders.edges[0].node.events.pageInfo.hasNextPage
            $OrderHasNextPage = $Response.data.orders.pageInfo.hasNextPage
    
            while ($LineItemHasNextPage) {
                try {
                    $LineItemResponse = Invoke-ShopifyAPIFunction -ShopName $ShopName -Body $Query.Invoke($QueryString, $CurrentOrderCursor, $LineItemCursor, $EventCursor)
                    $CurrentOrder.lineItems.edges += $LineItemResponse.data.orders.edges[0].node.lineItems.edges[0]
                    $LineItemCursor = $LineItemResponse.data.orders.edges[0].node.lineItems.edges[0].cursor
                    $LineItemHasNextPage = $LineItemResponse.data.orders.edges[0].node.lineItems.pageInfo.hasNextPage
                } catch {
                    Write-Warning "Retrying line item fetch"
                    Start-Sleep -Seconds 5
                }
            }

            # # Commenting out until exchanges are visited
            # while ($EventHasNextPage) {
            #     try {
            #         $EventResponse = Invoke-ShopifyAPIFunction -ShopName $ShopName -Body $Query.Invoke($QueryString, $CurrentOrderCursor, $LineItemCursor, $EventCursor)
            #         $CurrentOrder.events.edges += $EventResponse.data.orders.edges[0].node.events.edges[0]
            #         $EventCursor = $EventResponse.data.orders.edges[0].node.events.edges[0].cursor
            #         $EventHasNextPage = $EventResponse.data.orders.edges[0].node.events.pageInfo.hasNextPage
            #     } catch {
            #         Write-Warning "Retrying event fetch"
            #         Start-Sleep -Seconds 5
            #     }
            # }
            
            $Orders += $CurrentOrder
            $CurrentOrderCursor = $NextOrderCursor
            $LineItemCursor = ""
            $EventCursor = ""
        } catch {
            Write-Warning "Retrying order fetch"
            $Retry = $true
            Start-Sleep -Seconds 5
        }
    } while ($OrderHasNextPage -or $Retry)
    
    return $Orders
}

function Get-ShopifyOrdersInDateRange {
    param (
        [Parameter(Mandatory)]$ShopName,
        $StartDate = (Get-Date).AddDays(-1), 
        $EndDate = (Get-Date)
    )

    try {
        $UTCStartDate = Get-Date -Date (Get-Date -Date $StartDate).ToUniversalTime() -Format o 
        $UTCEndDate = Get-Date -Date (Get-Date -Date $EndDate).ToUniversalTime() -Format o
    } catch {
        throw "Invalid date specified."
    }

    $QueryString = "created_at:>=$UTCStartDate created_at:<=$UTCEndDate"

    Get-ShopifyOrders -ShopName $ShopName -QueryString $QueryString
}

function Get-ShopifyIdFromShopifyGid {
    param (
        [Parameter(Mandatory,ValueFromPipeline)]$ShopifyGid
    )

    process { $ShopifyGid -split "/" | Select-Object -Last 1 }
}

function Set-ShopifyOrderTag {
    param (
        [Parameter(Mandatory)]$ShopName,
        [Parameter(Mandatory,ValueFromPipeline)]$Order,
        $AddTag,
        $RemoveTag
    )
    process {
        [array]$Tags = $Order.Tags
        $Tags += $AddTag
        $Tags = $Tags | Where-Object {$_ -notin $RemoveTag}
        $Base64EncodedGID = $Order.id | ConvertTo-Base64
        $FormattedTags = $Tags | ConvertTo-Json

        $Mutation = @"
            mutation {
                orderUpdate(input: {
                    id: "$Base64EncodedGID"
                    tags: $FormattedTags
                }) {
                    order {
                        id
                        tags
                    }
                    userErrors {
                        field
                        message
                    }
                }
            }
"@
        $Response = Invoke-ShopifyAPIFunction -ShopName $ShopName -Body $Mutation
        if ($Response.data.orderUpdate.userErrors) {
            throw $Response.data.orderUpdate.userErrors[0].message
        } else {
            $Order.Tags = $Response.data.orderUpdate.order.tags
            return $Response.data.orderUpdate.order
        }
    }
}

function Get-ShopifyRestOrderTransactionDetail {
    param (
        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]$LegacyResourceId,
        [Parameter(Mandatory)]$ShopName
    )
    process {
        Invoke-ShopifyRestAPIFunction -HttpMethod GET -ShopName $ShopName -Resource Orders -Subresource $LegacyResourceId/Transactions |
            Select-Object -ExpandProperty Transactions |
            Where-Object kind -eq "sale" |
            Where-Object gateway -NE "exchange-credit" | 
            Where-Object {-not $_.error_code}
    }
}

function Update-ShopifyInventoryLevelAtLocation {
    param (
        [Parameter(Mandatory)]$ShopName,
        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]$InventoryItemGid,
        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]$LocationGid,
        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]$Delta
    )
    process {

    }
}

function Get-ShopifyInventoryLevelAtLocation {
    param (
        [Parameter(Mandatory)]$ShopName,
        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]$SKU,
        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]$LocationId
    )
    
    $Query = @"
        {
            inventoryItems (first: 1, query:"sku:$SKU") {
                edges {
                    node {
                        id
                        inventoryLevel (locationId: "gid://shopify/Location/$LocationId") {
                            id
                            location {
                                id
                                name
                            }
                            available
                        }
                    }
                }
            }
        }
"@
    $Result = Invoke-ShopifyAPIFunction -ShopName $ShopName -Body $Query
    $Result.data.inventoryItems.edges.node
}

function Get-ShopifyLocation {
    param (
        [Parameter(Mandatory)]$ShopName,
        [Parameter(Mandatory)]$LocationName
    )

    $Query = {
        param ($Name,$Cursor)
        @"
            {
                locations (
                    first: 10, query:"name:$Name"
                    $(
                        if ($Cursor) {", after:`"$Cursor`""}
                    )
                ) {
                    edges {
                        node {
                            id
                            name
                            address {
                                address1
                                address2
                                city
                                provinceCode
                                zip
                            }
                            isActive                    
                        }
                        cursor
                    }
                    pageInfo {
                        hasNextPage
                    }
                }
            }
"@
    } 
    $Result = @()
    do {
        $Response = Invoke-ShopifyAPIFunction -ShopName $ShopName -Body $Query.Invoke($LocationName,$Cursor)
        $Cursor = $Response.data.locations.edges.cursor | Select-Object -Last 1
        $Result += $Response.data.locations.edges.node
    } while ($Response.data.locations.pageInfo.hasNextPage)
    return $Result   
}

function Get-ShopifyRefunds {
    param (
        [Parameter(Mandatory)]$ShopName,
        [Parameter(Mandatory)]$OrderGID
    )

    $Query = {
        param ($OrderGID,$Cursor)
        @"
        {
            order(id:"$OrderGID") {
                refunds {
                    id
                    createdAt
                    refundLineItems (
                        first: 1
                        $(
                            if ($Cursor) {", after:`"$Cursor`""}
                        )
    
                    ) {
                        edges {
                            node {
                                restocked
                                lineItem {
                                    sku
                                    quantity
                                    originalUnitPriceSet {
                                        shopMoney {
                                            amount
                                        }
                                    }
                                    discountedUnitPriceSet {
                                        shopMoney {
                                            amount
                                        }
                                    }
                                    discountedTotalSet {
                                        shopMoney {
                                            amount
                                        }
                                    }
                                }
                                priceSet {
                                    shopMoney {
                                        amount
                                    }
                                }
                                quantity
                                totalTaxSet {
                                    shopMoney {
                                        amount
                                    }
                                }
                            }
                            cursor
                        }
                        pageInfo {
                            hasNextPage
                        }
                    }
                    transactions(first:3) {
                        edges {
                            node {
                                gateway
                                amountSet {
                                    shopMoney {
                                        amount
                                    }
                                }
                            }
                        }
                    }
                    totalRefundedSet {
                        shopMoney {
                            amount
                        }
                    }
                }
            }
        }
"@
    }    
    $Response = Invoke-ShopifyAPIFunction -ShopName $ShopName -Body $Query.Invoke($OrderGID)
    $RefundIDs = $Response.data.order.refunds.id
    $Result = @()
    
    foreach ($RefundID in $RefundIDs) {
        $Refund = $Response.data.order.refunds | Where-Object id -eq $RefundID
        $LineItems = @()
        do {
            $Response = Invoke-ShopifyAPIFunction -ShopName $ShopName -Body $Query.Invoke($OrderGID,$Cursor)
            $Refund = $Response.data.order.refunds | Where-Object id -eq $RefundID
            $Cursor = $Refund.refundLineItems.edges[0].cursor
            $LineItems += $Refund.refundLineItems.edges[0]
        } while ($Refund.refundLineItems.pageInfo.hasNextPage)
        $Refund.refundLineItems.edges = $LineItems
        $Result += $Refund
    }
    
    return $Result
}

function Get-ShopifyOrder {
    param (
        [Parameter(Mandatory)]$ShopName,
        [Parameter(Mandatory)]$OrderId
    )
    $Query = {
        param ($OrderId, $LineItemCursor, $EventCursor)
        @"
        query {
            order(id:"gid://shopify/Order/$OrderId") {
                id
                legacyResourceId
                createdAt
                tags
                customAttributes {
                    key
                    value
                }
                customer {
                    displayName
                    firstName
                    lastName
                    defaultAddress {
                        address1
                        address2
                        city
                        province
                        zip
                        name
                        countryCodeV2
                    }
                }
                physicalLocation {
                    name
                    address {
                        city
                    }
                }
                fulfillable
                lineItems(first: 1 $(if ($LineItemCursor) {", after:`"$LineItemCursor`""} )) {
                    edges {
                        node {
                            name
                            sku
                            quantity
                            variant {
                                barcode
                            }
                            originalUnitPriceSet {
                                shopMoney {
                                    amount
                                }
                            }
                            discountedUnitPriceSet {
                                shopMoney {
                                    amount
                                }
                            }
                            discountedTotalSet {
                                shopMoney {
                                    amount
                                }
                            }
                            taxLines {
                                priceSet {
                                    shopMoney {
                                        amount
                                    }
                                }
                            }
                            customAttributes {
                                key
                                value
                            }
                        }
                        cursor
                    }
                    pageInfo {
                        hasNextPage
                    }
                }
                shippingLine {
                    discountedPriceSet {
                        shopMoney {
                            amount
                        }
                    }
                    taxLines {
                        priceSet {
                            shopMoney {
                                amount
                            }
                        }
                    }
                }
                events(first: 1 $(if ($EventCursor) {", after:`"$EventCursor`""} )) {
                    edges {
                        node {
                            id
                            message
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
    
    }
    # do {
        try {
            $Retry = $false
            $Response = Invoke-ShopifyAPIFunction -ShopName $ShopName -Body $Query.Invoke($OrderId, $LineItemCursor, $EventCursor)
            if (-not $Response.data.order) {break}
            $CurrentOrder = $Response.data.order
    
            # $NextOrderCursor = $Response.data.orders.edges[0].cursor
            $LineItemCursor = $Response.data.order.lineItems.edges[0].cursor
            $LineItemHasNextPage = $Response.data.order.lineItems.pageInfo.hasNextPage
            $EventCursor = $Response.data.order.events.edges[0].cursor
            $EventHasNextPage = $Response.data.order.events.pageInfo.hasNextPage
            # $OrderHasNextPage = $Response.data.orders.pageInfo.hasNextPage
    
            while ($LineItemHasNextPage) {
                try {
                    $LineItemResponse = Invoke-ShopifyAPIFunction -ShopName $ShopName -Body $Query.Invoke($OrderId, $LineItemCursor, $EventCursor)
                    $CurrentOrder.lineItems.edges += $LineItemResponse.data.order.lineItems.edges[0]
                    $LineItemCursor = $LineItemResponse.data.order.lineItems.edges[0].cursor
                    $LineItemHasNextPage = $LineItemResponse.data.order.lineItems.pageInfo.hasNextPage
                } catch {
                    Write-Warning "Retrying line item fetch"
                    Start-Sleep -Seconds 5
                }
            }

            while ($EventHasNextPage) {
                try {
                    $EventResponse = Invoke-ShopifyAPIFunction -ShopName $ShopName -Body $Query.Invoke($OrderId, $LineItemCursor, $EventCursor)
                    $CurrentOrder.events.edges += $EventResponse.data.order.events.edges[0]
                    $EventCursor = $EventResponse.data.order.events.edges[0].cursor
                    $EventHasNextPage = $EventResponse.data.order.events.pageInfo.hasNextPage
                } catch {
                    Write-Warning "Retrying event fetch"
                    Start-Sleep -Seconds 5
                }
            }
            
            # $Orders += $CurrentOrder
            # $CurrentOrderCursor = $NextOrderCursor
            $LineItemCursor = ""
            $EventCursor = ""
        } catch {
            # Write-Warning "Retrying order fetch"
            # $Retry = $true
            # Start-Sleep -Seconds 5
            throw "Could not get Order #$OrderId"
        }
    # } while ($OrderHasNextPage -or $Retry)
    
    # return $Orders
    return $CurrentOrder
}

function Add-ShopifyTag {
    param (
        [Parameter(Mandatory)]$ShopName,
        [Parameter(Mandatory)]$ShopifyGid,
        [array]$Tags
    )
    $Base64EncodedGID = $ShopifyGid | ConvertTo-Base64
    $TagsString = $Tags -join "`",`""
    $Mutation = @"
        mutation {
            tagsAdd (
                id: "$Base64EncodedGID" 
                tags: ["$TagsString"]
            ) {
                node {
                    id
                }
                userErrors {
                    field
                    message
                }
            }
        }
"@
    try {
        $Response = Invoke-ShopifyAPIFunction -ShopName $ShopName -Body $Mutation
        if ($Response.data.tagsAdd.userErrors) { throw $Response.data.tagsAdd.userErrors.message }
        if (-not $Response.data.tagsAdd.node.id) { throw "No node ID returned."}
        Write-Output "$ShopifyGid`: Added tags successfully."
    } catch {
        Write-Warning "$ShopifyGid`: Could not add tags. $_"
        continue
    }
}

function Remove-ShopifyTag {
    param (
        [Parameter(Mandatory)]$ShopName,
        [Parameter(Mandatory)]$ShopifyGid,
        [Parameter(Mandatory)][array]$Tags
    )
    $Base64EncodedGID = $ShopifyGid | ConvertTo-Base64
    $TagsString = $Tags -join "`",`""
    $Mutation = @"
        mutation {
            tagsRemove (
                id: "$Base64EncodedGID" 
                tags: ["$TagsString"]
            ) {
                node {
                    id
                }
                userErrors {
                    field
                    message
                }
            }
        }
"@
    try {
        $Response = Invoke-ShopifyAPIFunction -ShopName $ShopName -Body $Mutation
        if ($Response.data.tagsRemove.userErrors) { throw $Response.data.tagsRemove.userErrors.message }
        if (-not $Response.data.tagsRemove.node.id) { throw "No node ID returned."}
        Write-Output "$ShopifyGid`: Removed tags successfully."
    } catch {
        Write-Warning "$ShopifyGid`: Could not remove tags. $_"
        continue
    }
}
